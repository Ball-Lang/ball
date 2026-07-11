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
    /// construct outside this encoder's documented scope — never a silent drop.</summary>
    public static Program Encode(string source)
    {
        var module = EncodeMainModule(source, out var hasMain);
        if (!hasMain)
        {
            throw new EncoderException(
                "ball-encoder: a Ball Program requires a `Main` entry point (C# top-level " +
                "statements, or a class with `static void Main()`/`static int Main()`)");
        }

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
            EntryFunction = "Main",
        };
    }

    /// <summary>Encode a C# source file's declarations into a bare <c>"main"</c>
    /// <see cref="Module"/> — without requiring an entry point or including the base modules.
    /// Exists for tests that want to inspect the encoded <see cref="FunctionDefinition"/>/
    /// <see cref="Expression"/> tree directly. <see cref="Encode"/> is the entry point for a
    /// complete, runnable <see cref="Program"/>.</summary>
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
            if (typeDecl is not TypeDeclarationSyntax classLike)
            {
                // `enum` declarations are a documented gap for this issue's scope (not part
                // of the explicit construct list) — fail loud rather than silently drop.
                throw new EncoderException(
                    $"ball-encoder: unsupported type declaration kind `{typeDecl.Kind()}` " +
                    "(only class/struct/record declarations are supported — issue #382's scope)");
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
