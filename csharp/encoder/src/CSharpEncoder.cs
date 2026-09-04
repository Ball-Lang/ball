using System;
using System.Collections.Generic;
using System.Linq;
using Ball.Shared;
using Ball.V1;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace Ball.Encoder;

/// <summary>
/// Encodes C# source into a Ball <see cref="Program"/> protobuf (issue #382).
///
/// Parses with Roslyn's <see cref="CSharpSyntaxTree"/> — the official AST API — used
/// <b>syntax-only</b> (<c>ParseText</c>, no <c>CSharpCompilation</c>/semantic model), mirroring
/// <c>dart/encoder/lib/encoder.dart</c>'s <c>parseString</c> approach and the syntactic-encoder
/// dispatch-by-name-heuristic discipline documented in <c>.claude/rules/dart.md</c>. Closest
/// sibling in spirit is <c>rust/encoder/src/lib.rs</c> (an official-AST, syntax-only encoder in
/// a statically-typed host language) — this crate mirrors its module layout (one file per
/// concern) and its free-function expression-builder toolbox (<see cref="Builders"/>).
///
/// <b>Core invariant (never violate): there is no <c>csharp_std</c> base module.</b> Every C#
/// construct — operators, control flow, LINQ-lite chains, string interpolation, null-conditional
/// access, object initializers — expands into a tree of calls against the universal
/// <c>std</c>/<c>std_collections</c> base functions. A conformant Ball engine that has never
/// heard of C# can still run the result.
///
/// ## The "one input" convention, precisely (verified against the reference engine)
///
/// Unlike <c>rust/encoder</c> (which packs 2+ parameters into an anonymous
/// <c>field_access(reference("input"), name)</c> tree to work around its *compiled-Rust-closure*
/// target), this encoder targets the tree-walking reference engine directly, and
/// <c>dart/engine/lib/engine_invocation.dart</c>'s <c>_callFunction</c> binds <b>every</b>
/// declared parameter — 1 or many — directly under its own real name whenever
/// <c>FunctionDefinition.metadata.params</c> lists it (this is engine-level behavior, not merely
/// compiler-cosmetic — see <see cref="Builders.ParamsMetadata"/>'s doc comment). So every
/// function/method/lambda this encoder emits, regardless of arity, references each of its
/// parameters via a plain <c>reference(name)</c> throughout its body — no positional
/// <c>arg0</c>/<c>arg1</c> packing is ever needed for a *known* (same-file) callee. Lambdas are
/// true closures on the reference engine (<c>_evalLambda</c> captures <c>scope.child()</c>), so
/// nested lambdas referencing an enclosing function's parameters by name resolve correctly with
/// no special-casing.
///
/// Instance methods use the engine's separate, <b>unconditional</b> <c>self</c> convention: a
/// call's <c>input</c> messageCreation carries a <c>"self"</c> field with the receiver, and the
/// engine binds <c>self</c> into scope (and flattens the receiver's own fields into scope too)
/// whenever that key is present — independent of what <c>metadata.params</c> says. This encoder
/// lists only the method's own (non-<c>self</c>) parameters in <c>metadata.params</c> and always
/// addresses a field via the explicit <c>field_access(reference("self"), field)</c> shape (never
/// a bare identifier), for clarity and because a syntax-only encoder cannot always disambiguate
/// a bare name as "local variable" vs. "instance field" without tracking a lexical scope stack
/// (which this encoder does — see <see cref="Encoder.IsKnownLocal"/>).
/// </summary>
public static class CSharpEncoder
{
    /// <summary>Encode a whole C# source file into a runnable Ball <see cref="Program"/>.
    /// Requires an entry point — either C# 9+ top-level statements, or a class containing
    /// <c>static void Main()</c>/<c>static int Main()</c>/<c>static void Main(string[] args)</c>
    /// — encoded as a Ball function literally named <c>"Main"</c>. Fails loud
    /// (<see cref="EncoderException"/>) on a parse error, a missing entry point, or any
    /// construct outside this encoder's documented scope — never a silent drop. Source with no
    /// entry point — a class library — is encoded by <see cref="EncodeLibrary"/> instead
    /// (<c>ball encode --library</c>).</summary>
    public static Program Encode(string source)
    {
        var module = EncodeMainModule(source, out var hasMain);
        if (!hasMain)
        {
            throw new EncoderException(
                "ball-encoder: a Ball Program requires a `Main` entry point (C# top-level " +
                "statements, or a class with `static void Main()`/`static int Main()`)");
        }

        return AssembleProgram(module, entryFunction: "Main");
    }

    /// <summary>Encode a C# <b>library</b> source file into a Ball <see cref="Program"/>
    /// (issue #492) — the same encoding as <see cref="Encode"/>, minus the <c>Main</c>
    /// entry-point requirement. Real class libraries have no entry point, so
    /// <see cref="Encode"/> rejects every one of them; this is the opt-in that accepts them
    /// (<c>ball encode --library</c>).
    ///
    /// <para><b>Deliberately non-runnable.</b> The returned <see cref="Program"/> carries
    /// <c>EntryModule = "main"</c> (the module whose declarations were encoded) but an
    /// <b>empty</b> <c>EntryFunction</c>. <c>Program.entry_function</c> is an unconstrained
    /// proto3 string, so an empty one is structurally legal and deliberately not runnable:
    /// <c>ball check</c> reports <c>missing entry_function</c>
    /// (<c>csharp/cli/src/Commands/CheckCommand.cs</c>) and <c>ball run</c> has nothing to call.
    /// That is the documented boundary — mirrored exactly by the Rust encoder's
    /// <c>encode_library</c> — and must never be papered over by synthesising a fake entry
    /// function.</para>
    ///
    /// <para>Every other documented scope gap still throws
    /// <see cref="EncoderException"/> unchanged: this relaxes the entry-point requirement,
    /// nothing else.</para></summary>
    public static Program EncodeLibrary(string source)
    {
        var module = EncodeMainModule(source, out _);
        return AssembleProgram(module, entryFunction: string.Empty);
    }

    /// <summary>Wrap an encoded <c>"main"</c> <see cref="Module"/> in a
    /// <see cref="Program"/>, accumulating the <c>std</c>/<c>std_collections</c>/… base modules
    /// the module's functions actually call. Shared by <see cref="Encode"/> and
    /// <see cref="EncodeLibrary"/>; <paramref name="entryFunction"/> is the only difference
    /// between the two (<c>"Main"</c> vs. <c>""</c> — see
    /// <see cref="EncodeLibrary"/>'s "Deliberately non-runnable").</summary>
    private static Program AssembleProgram(Module module, string entryFunction)
    {
        var used = new Dictionary<string, HashSet<string>>();
        foreach (var func in module.Functions)
        {
            if (func.Body is not null)
            {
                CollectUsedFunctions(func.Body, used);
            }
        }

        // `std` is always present (mirrors every reference encoder's own unconditional
        // inclusion) — every other base module is included only when actually referenced.
        var modules = new List<Module>
        {
            BuildUsedModule("std", used.TryGetValue("std", out var stdUsed) ? stdUsed : new HashSet<string>()),
        };
        foreach (var name in used.Keys.Where(k => k != "std").OrderBy(k => k, StringComparer.Ordinal))
        {
            modules.Add(BuildUsedModule(name, used[name]));
        }

        modules.Add(module);

        return new Program
        {
            Name = "encoded_csharp_program",
            Version = "1.0.0",
            Modules = { modules },
            EntryModule = "main",
            EntryFunction = entryFunction,
        };
    }

    /// <summary>Encode a C# source file's declarations into a bare <c>"main"</c>
    /// <see cref="Module"/> — without requiring an entry point or including the base modules.
    /// Exists for tests that want to inspect the encoded <see cref="FunctionDefinition"/>/
    /// <see cref="Expression"/> tree directly. <see cref="Encode"/> is the entry point for a
    /// complete, runnable <see cref="Program"/>; <see cref="EncodeLibrary"/> produces the same
    /// <see cref="Program"/> shape (base modules attached) for entry-point-less library
    /// source.</summary>
    internal static Module EncodeModuleOnly(string source) => EncodeMainModule(source, out _);

    private static Module EncodeMainModule(string source, out bool hasMain)
    {
        var tree = CSharpSyntaxTree.ParseText(source);
        var errors = tree.GetDiagnostics()
            .Where(d => d.Severity == DiagnosticSeverity.Error)
            .ToList();
        if (errors.Count > 0)
        {
            throw new EncoderException(
                $"ball-encoder: failed to parse C# source: {string.Join("; ", errors)}");
        }

        var root = (CompilationUnitSyntax)tree.GetRoot();
        var members = FlattenMembers(root.Members).ToList();

        var globalStatements = members.OfType<GlobalStatementSyntax>().Select(g => g.Statement).ToList();
        var typeDecls = members.OfType<BaseTypeDeclarationSyntax>().ToList();
        var unsupported = members.Where(m => m is not GlobalStatementSyntax and not BaseTypeDeclarationSyntax).ToList();
        if (unsupported.Count > 0)
        {
            throw new EncoderException(
                "ball-encoder: unsupported top-level declaration `" +
                unsupported[0].Kind() + "` — only top-level statements and class/struct/record " +
                "declarations are supported (issue #382's scope)");
        }

        var encoder = new Encoder();
        encoder.CollectDeclarations(typeDecls);

        var functions = new List<FunctionDefinition>();
        var enums = new List<Google.Protobuf.Reflection.EnumDescriptorProto>();
        var typeDefList = new List<TypeDefinition>();

        hasMain = false;
        if (globalStatements.Count > 0)
        {
            hasMain = true;
            functions.Add(encoder.EncodeTopLevelMain(globalStatements));
        }

        foreach (var typeDecl in typeDecls)
        {
            // An `enum` declaration encodes to a `Module.Enums[]` entry plus a companion,
            // descriptor-less `TypeDefinition` (issue #492, slice C) — the shape
            // `csharp/compiler/src/TypeEmit.cs`'s `CompileEnum` has always consumed, and the
            // same one `rust/encoder/src/types.rs` emits.
            if (typeDecl is EnumDeclarationSyntax enumDecl)
            {
                var (enumTypeDef, enumDef) = encoder.EncodeEnumDeclaration(enumDecl);
                typeDefList.Add(enumTypeDef);
                enums.Add(enumDef);
                continue;
            }

            if (typeDecl is not TypeDeclarationSyntax classLike)
            {
                // Exhaustiveness guard. `BaseTypeDeclarationSyntax` has exactly two subclasses
                // in Roslyn today — `TypeDeclarationSyntax` (class/struct/interface/record) and
                // the `EnumDeclarationSyntax` handled just above — so nothing reaches here now.
                // It stays so that a future Roslyn declaration kind fails loud instead of being
                // silently dropped from the encoded module. (A `delegate` is NOT a
                // `BaseTypeDeclarationSyntax`; it is rejected earlier, by the top-level
                // "unsupported top-level declaration" check.)
                throw new EncoderException(
                    $"ball-encoder: unsupported type declaration kind `{typeDecl.Kind()}` " +
                    "(only class/struct/record/enum declarations are supported — issue #382's scope)");
            }

            var (typeDef, members2) = encoder.EncodeTypeDeclaration(classLike);
            typeDefList.Add(typeDef);

            foreach (var member in members2)
            {
                if (member.Name == "Main")
                {
                    if (hasMain)
                    {
                        throw new EncoderException("ball-encoder: multiple `Main` entry points found");
                    }

                    hasMain = true;
                }

                functions.Add(member);
            }
        }

        var moduleImports = new List<ModuleImport> { new() { Name = "std" } };
        if (encoder.UsesCollections)
        {
            moduleImports.Add(new ModuleImport { Name = "std_collections" });
        }

        var mainModule = new Module { Name = "main" };
        mainModule.ModuleImports.AddRange(moduleImports);
        mainModule.Functions.AddRange(functions);
        mainModule.TypeDefs.AddRange(typeDefList);
        mainModule.Enums.AddRange(enums);
        return mainModule;
    }

    /// <summary>Unwrap namespace declarations (both file-scoped and block-scoped) so their
    /// members are treated as top-level — Ball has no namespace concept of its own; every
    /// user type/function already lives in a single flat <c>"main"</c> module (see
    /// <c>Types.QualifiedTypeName</c>).</summary>
    private static IEnumerable<MemberDeclarationSyntax> FlattenMembers(
        IEnumerable<MemberDeclarationSyntax> members)
    {
        foreach (var member in members)
        {
            switch (member)
            {
                case NamespaceDeclarationSyntax ns:
                    foreach (var inner in FlattenMembers(ns.Members))
                    {
                        yield return inner;
                    }

                    break;
                case FileScopedNamespaceDeclarationSyntax fileNs:
                    foreach (var inner in FlattenMembers(fileNs.Members))
                    {
                        yield return inner;
                    }

                    break;
                default:
                    yield return member;
                    break;
            }
        }
    }

    /// <summary>Walk an encoded <see cref="Expression"/> tree, recording every
    /// <c>(module, function)</c> pair a <c>call</c> node references — the "std accumulation"
    /// pass (mirrors <c>rust/encoder/src/lib.rs::collect_used_functions</c> and
    /// <c>dart/encoder/lib/encoder.dart</c>'s own <c>_usedBaseFunctions</c> tracking). A
    /// <c>call.Module</c> of <c>""</c> (an unqualified same-file user function/method/lambda
    /// call) is deliberately not recorded — only genuine base-module calls are declarations.</summary>
    private static void CollectUsedFunctions(Expression expr, Dictionary<string, HashSet<string>> used)
    {
        switch (expr.ExprCase)
        {
            case Expression.ExprOneofCase.Call:
                var call = expr.Call;
                if (!string.IsNullOrEmpty(call.Module))
                {
                    if (!used.TryGetValue(call.Module, out var set))
                    {
                        set = new HashSet<string>();
                        used[call.Module] = set;
                    }

                    set.Add(call.Function);
                }

                if (call.Input is not null)
                {
                    CollectUsedFunctions(call.Input, used);
                }

                break;
            case Expression.ExprOneofCase.Literal:
                if (expr.Literal.ValueCase == Literal.ValueOneofCase.ListValue)
                {
                    foreach (var element in expr.Literal.ListValue.Elements)
                    {
                        CollectUsedFunctions(element, used);
                    }
                }

                break;
            case Expression.ExprOneofCase.FieldAccess:
                if (expr.FieldAccess.Object is not null)
                {
                    CollectUsedFunctions(expr.FieldAccess.Object, used);
                }

                break;
            case Expression.ExprOneofCase.MessageCreation:
                foreach (var field in expr.MessageCreation.Fields)
                {
                    if (field.Value is not null)
                    {
                        CollectUsedFunctions(field.Value, used);
                    }
                }

                break;
            case Expression.ExprOneofCase.Block:
                foreach (var statement in expr.Block.Statements)
                {
                    switch (statement.StmtCase)
                    {
                        case Statement.StmtOneofCase.Let when statement.Let.Value is not null:
                            CollectUsedFunctions(statement.Let.Value, used);
                            break;
                        case Statement.StmtOneofCase.Expression:
                            CollectUsedFunctions(statement.Expression, used);
                            break;
                    }
                }

                if (expr.Block.Result is not null)
                {
                    CollectUsedFunctions(expr.Block.Result, used);
                }

                break;
            case Expression.ExprOneofCase.Lambda:
                if (expr.Lambda.Body is not null)
                {
                    CollectUsedFunctions(expr.Lambda.Body, used);
                }

                break;
        }
    }

    /// <summary>Build a base module declaring exactly <paramref name="fnNames"/>, reusing the
    /// canonical <see cref="StdModuleBuilders"/> descriptors (function description/input-type,
    /// and every documented <c>TypeDef</c>) so a typo in a used-function name fails loud here
    /// rather than silently producing an unresolvable call at run time — "StdModuleBuilders from
    /// shared", per issue #382.</summary>
    private static Module BuildUsedModule(string name, HashSet<string> fnNames)
    {
        var canonical = name switch
        {
            "std" => StdModuleBuilders.BuildStdModule(),
            "std_collections" => StdModuleBuilders.BuildStdCollectionsModule(),
            "std_io" => StdModuleBuilders.BuildStdIoModule(),
            "std_memory" => StdModuleBuilders.BuildStdMemoryModule(),
            _ => throw new EncoderException($"ball-encoder: internal error — unknown base module `{name}`"),
        };

        var module = new Module { Name = name, Description = canonical.Description };
        module.TypeDefs.AddRange(canonical.TypeDefs);
        var byName = canonical.Functions.ToDictionary(f => f.Name);
        foreach (var fnName in fnNames.OrderBy(n => n, StringComparer.Ordinal))
        {
            if (!byName.TryGetValue(fnName, out var fn))
            {
                throw new EncoderException(
                    $"ball-encoder: internal error — used base function `{name}.{fnName}` is not " +
                    "in the canonical inventory (StdModuleBuilders)");
            }

            module.Functions.Add(fn);
        }

        return module;
    }
}
