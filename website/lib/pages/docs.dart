import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/navbar.dart';
import '../components/footer.dart';
import '../components/code_block.dart';

class DocsPage extends StatelessComponent {
  const DocsPage({super.key});

  @override
  Component build(BuildContext context) {
    return .fragment([
      const Navbar(),
      _buildHeader(),
      _buildContent(),
      const Footer(),
    ]);
  }

  Component _buildHeader() {
    return section(classes: 'docs-header', [
      div(classes: 'docs-header-inner', [
        span(classes: 'section-label', [Component.text('DOCUMENTATION')]),
        h1(classes: 'docs-title', [Component.text('Learn Ball')]),
        p(classes: 'docs-subtitle', [
          Component.text(
            'Everything you need to understand, build, and extend the Ball programming language.',
          ),
        ]),
      ]),
    ]);
  }

  Component _buildContent() {
    return div(classes: 'docs-content', [
      div(classes: 'docs-inner', [
        // Overview
        _buildSection(
          'overview',
          'Overview',
          'What is Ball?',
          [
            p(classes: 'docs-text', [
              Component.text(
                'Ball is a programming language where every program is a Protocol Buffer message. '
                'Instead of text files that are parsed into ASTs, your code starts as structured data \u2014 '
                'a protobuf message that can be serialized, stored in databases, sent over gRPC, '
                'inspected, transformed, and compiled to any target language.',
              ),
            ]),
            p(classes: 'docs-text', [
              Component.text(
                'The language schema is defined in a single file: ',
              ),
              code([Component.text('proto/ball/v1/ball.proto')]),
              Component.text(
                '. This proto file is the canonical source of truth for what a valid Ball program looks like.',
              ),
            ]),
          ],
        ),

        // Design Principles
        _buildSection(
          'principles',
          'Core Design',
          'Design principles',
          [
            _buildPrinciple(
              '1. One input, one output per function',
              'Every function takes a single input message and returns a single output message, '
                  'following the gRPC pattern. This is not a limitation \u2014 it IS the design. '
                  'Multiple parameters are expressed as fields of the input message.',
            ),
            _buildPrinciple(
              '2. Code is protobuf messages',
              'The entire AST \u2014 expression tree, modules, functions, types \u2014 is defined in ball.proto. '
                  'Programs can be serialized to binary protobuf or JSON. If it deserializes, it\u2019s structurally valid.',
            ),
            _buildPrinciple(
              '3. Semantic vs. cosmetic boundary',
              'The expression tree, function signatures, type descriptors, and module structure are semantic. '
                  'Everything else (visibility, mutability, annotations, syntax sugar) is cosmetic metadata. '
                  'A Ball program with all metadata stripped computes the same result.',
            ),
            _buildPrinciple(
              '4. Base functions have no body',
              'Base functions are declared with isBase: true and have no body expression. '
                  'Their implementation is provided by each target language\u2019s compiler/engine. '
                  'This is the extensibility mechanism.',
            ),
            _buildPrinciple(
              '5. Control flow is function calls',
              'if, for, while, switch, try \u2014 they\u2019re all std base functions. '
                  'This keeps the language uniform. Compilers must handle them with lazy evaluation '
                  '(don\u2019t evaluate all branches before choosing one).',
            ),
            _buildPrinciple(
              '6. Types use protobuf descriptors',
              'Ball does NOT invent its own type system. It uses google.protobuf.DescriptorProto '
                  'and FieldDescriptorProto, which already define how types map to every target language\u2019s native types.',
            ),
          ],
        ),

        // Program Structure
        _buildSection(
          'structure',
          'Program Structure',
          'Anatomy of a Ball program',
          [
            p(classes: 'docs-text', [
              Component.text(
                'A Ball program is a Program protobuf message that contains modules, '
                'which contain functions, types, constants, and imports.',
              ),
            ]),
            const CodeBlock(
              filename: 'Program structure (pseudo)',
              language: 'protobuf',
              code: 'Program\n'
                  ' \u251C\u2500\u2500 name, version, entryModule, entryFunction\n'
                  ' \u2514\u2500\u2500 modules[]\n'
                  '      \u251C\u2500\u2500 name, description\n'
                  '      \u251C\u2500\u2500 types[]           (google.protobuf.DescriptorProto)\n'
                  '      \u251C\u2500\u2500 typeDefs[]        (TypeDefinition)\n'
                  '      \u251C\u2500\u2500 typeAliases[]     (TypeAlias)\n'
                  '      \u251C\u2500\u2500 enums[]           (google.protobuf.EnumDescriptorProto)\n'
                  '      \u251C\u2500\u2500 moduleConstants[] (Constant)\n'
                  '      \u251C\u2500\u2500 functions[]       (FunctionDefinition)\n'
                  '      \u2514\u2500\u2500 moduleImports[]   (ModuleImport)',
            ),
          ],
        ),

        // Expression Tree
        _buildSection(
          'expressions',
          'Expression Tree',
          'The seven expression types',
          [
            p(classes: 'docs-text', [
              Component.text(
                'Every Ball computation is one of seven expression types. '
                'This is the core of the language:',
              ),
            ]),
            _buildExprTable(),
            p(classes: 'docs-text', [
              Component.text(
                'Blocks contain Statements (either LetBinding or bare Expression) followed by a '
                'result expression. LetBindings bind a name to a value with optional metadata '
                '(type, mutability: var/final/const).',
              ),
            ]),
          ],
        ),

        // Standard Library
        _buildSection(
          'stdlib',
          'Standard Library',
          'Built-in modules',
          [
            p(classes: 'docs-text', [
              Component.text(
                'Ball comes with a comprehensive standard library. All standard library functions are '
                'base functions \u2014 their implementation is provided by each target language.',
              ),
            ]),
            _buildStdTable(),
            h4(classes: 'docs-h4', [Component.text('std module highlights')]),
            _buildStdCategory('Arithmetic',
                'add, subtract, multiply, divide, divide_double, modulo, negate'),
            _buildStdCategory('Comparison',
                'equals, not_equals, less_than, greater_than, lte, gte'),
            _buildStdCategory('Logical', 'and, or, not'),
            _buildStdCategory('Bitwise',
                'bitwise_and, bitwise_or, bitwise_xor, bitwise_not, left_shift, right_shift'),
            _buildStdCategory('Strings',
                'string_length, string_contains, string_substring, string_replace, string_split, string_trim, string_to_upper, ...'),
            _buildStdCategory('Math',
                'math_abs, math_sqrt, math_pow, math_sin, math_cos, math_pi, math_e, math_clamp, ...'),
            _buildStdCategory('Regex',
                'regex_match, regex_find, regex_find_all, regex_replace, regex_replace_all'),
            _buildStdCategory('Control Flow',
                'if, for, for_in, while, do_while, switch, try, return, break, continue, throw, rethrow'),
            _buildStdCategory('Type Ops', 'is, is_not, as'),
            _buildStdCategory('Null Safety', 'null_coalesce, null_check'),
            _buildStdCategory('Async', 'yield, await'),
          ],
        ),

        // Module Imports
        _buildSection(
          'imports',
          'Module System',
          'Dependencies and imports',
          [
            p(classes: 'docs-text', [
              Component.text(
                'Ball supports resolving dependencies from four source types:',
              ),
            ]),
            ul(classes: 'docs-list', [
              li([
                strong([Component.text('HTTP/HTTPS')]),
                Component.text(' \u2014 download from any URL'),
              ]),
              li([
                strong([Component.text('File')]),
                Component.text(' \u2014 local filesystem path'),
              ]),
              li([
                strong([Component.text('Inline')]),
                Component.text(
                    ' \u2014 raw protobuf bytes or JSON embedded in the import'),
              ]),
              li([
                strong([Component.text('Git')]),
                Component.text(' \u2014 repository at a specific ref'),
              ]),
            ]),
            p(classes: 'docs-text', [
              Component.text(
                'Each import supports a SHA-256 integrity hash for supply-chain security.',
              ),
            ]),
          ],
        ),

        // Metadata
        _buildSection(
          'metadata',
          'Metadata',
          'Cosmetic metadata system',
          [
            p(classes: 'docs-text', [
              Component.text(
                'All metadata is cosmetic \u2014 it improves round-trip fidelity but doesn\u2019t change '
                'computation. Key metadata fields include:',
              ),
            ]),
            ul(classes: 'docs-list', [
              li([
                strong([Component.text('FunctionDefinition')]),
                Component.text(
                    ': kind (function/method/constructor/getter/setter/operator), params, visibility, is_async, is_static, annotations, type_params'),
              ]),
              li([
                strong([Component.text('TypeDefinition')]),
                Component.text(
                    ': kind (class/struct/interface/mixin/enum/sealed_class), superclass, interfaces, mixins, fields, is_abstract'),
              ]),
              li([
                strong([Component.text('LetBinding')]),
                Component.text(': type, mutability, is_final, is_const, is_late'),
              ]),
              li([
                strong([Component.text('Module')]),
                Component.text(
                    ': language-specific imports (dart_imports, cpp_includes, python_imports, go_imports, etc.)'),
              ]),
            ]),
          ],
        ),

        // NPM Packages
        _buildSection(
          'npm',
          'NPM Packages',
          'TypeScript / Node.js ecosystem',
          [
            p(classes: 'docs-text', [
              Component.text(
                'Ball ships four npm packages under the @ball-lang scope:',
              ),
            ]),
            _buildPackageRow('@ball-lang/engine',
                'Tree-walking Ball interpreter for Node.js'),
            _buildPackageRow('@ball-lang/compiler',
                'Ball \u2192 TypeScript compiler via ts-morph'),
            _buildPackageRow('@ball-lang/encoder',
                'TypeScript \u2192 Ball encoder using the TS compiler API'),
            _buildPackageRow('@ball-lang/cli',
                'CLI tool for running, compiling, and encoding Ball programs'),
            const CodeBlock(
              language: 'bash',
              code: '# Install the engine\n'
                  'npm install @ball-lang/engine\n'
                  '\n'
                  '# Run a Ball program\n'
                  'npx @ball-lang/cli run program.ball.json\n'
                  '\n'
                  '# Compile Ball \u2192 TypeScript\n'
                  'npx @ball-lang/compiler program.ball.json -o output.ts',
            ),
          ],
        ),

        // Self-Hosting
        _buildSection(
          'self-host',
          'Self-Hosting',
          'Ball compiles its own interpreter',
          [
            p(classes: 'docs-text', [
              Component.text(
                'Ball achieves self-hosting: the Dart engine (3000+ LOC) is encoded to Ball IR, '
                'then compiled to both TypeScript and C++. The compiled engines execute all 55 '
                'conformance programs with byte-identical output to the reference Dart engine.',
              ),
            ]),
            _buildStdCategory('Dart \u2192 Ball \u2192 TypeScript',
                '55/55 conformance, runs on Node.js'),
            _buildStdCategory('Dart \u2192 Ball \u2192 C++',
                '92/92 e2e tests, compiles via MSVC/GCC/Clang'),
            _buildStdCategory('Scale Validation',
                '103/103 top pub.dev packages round-trip'),
          ],
        ),

        // Getting Started
        _buildSection(
          'getting-started',
          'Getting Started',
          'Quick start guide',
          [
            h4(classes: 'docs-h4', [Component.text('Node.js / TypeScript')]),
            const CodeBlock(
              language: 'bash',
              code: '# Install and run\n'
                  'npm install @ball-lang/engine\n'
                  '\n'
                  '# In your code:\n'
                  'import { BallEngine } from "@ball-lang/engine";\n'
                  'const engine = new BallEngine(programJson);\n'
                  'engine.run();\n'
                  'console.log(engine.getOutput());',
            ),
            h4(classes: 'docs-h4', [Component.text('Dart')]),
            const CodeBlock(
              language: 'bash',
              code: '# Clone Ball\n'
                  'git clone https://github.com/Ball-Lang/ball.git\n'
                  'cd ball\n'
                  '\n'
                  '# Install Dart dependencies\n'
                  'cd dart && dart pub get\n'
                  '\n'
                  '# Run the engine tests\n'
                  'cd engine && dart test\n'
                  '\n'
                  '# Compile an example to Dart\n'
                  'cd ../compiler\n'
                  'dart run bin/compile.dart \\\n'
                  '  ../../examples/hello_world.ball.json',
            ),
            h4(classes: 'docs-h4', [Component.text('C++')]),
            const CodeBlock(
              language: 'bash',
              code: '# Build the C++ implementation\n'
                  'cd cpp && mkdir -p build && cd build\n'
                  'cmake .. && cmake --build .\n'
                  '\n'
                  '# Run conformance tests\n'
                  './test/test_conformance',
            ),
            p(classes: 'docs-text', [
              Component.text('The proto schema is published on Buf: '),
              a(
                href: 'https://buf.build/ball-lang/ball',
                attributes: {
                  'target': '_blank',
                  'rel': 'noopener noreferrer',
                },
                [Component.text('buf.build/ball-lang/ball')],
              ),
            ]),
          ],
        ),
      ]),
    ]);
  }

  Component _buildSection(
    String id,
    String label,
    String title,
    List<Component> children,
  ) {
    return section(classes: 'docs-section', attributes: {'id': id}, [
      span(classes: 'docs-label', [Component.text(label)]),
      h2(classes: 'docs-h2', [Component.text(title)]),
      ...children,
    ]);
  }

  Component _buildPrinciple(String title, String desc) {
    return div(classes: 'docs-principle', [
      h3(classes: 'docs-h3', [Component.text(title)]),
      p(classes: 'docs-text', [Component.text(desc)]),
    ]);
  }

  Component _buildExprTable() {
    return div(classes: 'docs-table-wrap', [
      table(classes: 'docs-table', [
        thead([
          tr([
            th([Component.text('Expression')]),
            th([Component.text('Meaning')]),
            th([Component.text('Example')]),
          ]),
        ]),
        tbody([
          _buildTableRow('call', 'Function call',
              '{module, function, input}'),
          _buildTableRow(
              'literal', 'Constant value', 'int, double, string, bool, bytes'),
          _buildTableRow(
              'reference', 'Variable reference', '"input" = function parameter'),
          _buildTableRow(
              'fieldAccess', 'Field access', '{object, field}'),
          _buildTableRow('messageCreation', 'Construct message',
              '{typeName, fields[]}'),
          _buildTableRow('block', 'Statement block',
              'let-bindings + result expression'),
          _buildTableRow(
              'lambda', 'Anonymous function', 'Closures'),
        ]),
      ]),
    ]);
  }

  Component _buildTableRow(String expr, String meaning, String example) {
    return tr([
      td([code([Component.text(expr)])]),
      td([Component.text(meaning)]),
      td(classes: 'table-example', [Component.text(example)]),
    ]);
  }

  Component _buildStdTable() {
    return div(classes: 'docs-table-wrap', [
      table(classes: 'docs-table', [
        thead([
          tr([
            th([Component.text('Module')]),
            th([Component.text('Functions')]),
            th([Component.text('Description')]),
          ]),
        ]),
        tbody([
          tr([
            td([code([Component.text('std')])]),
            td([Component.text('~120')]),
            td([
              Component.text(
                  'Arithmetic, comparison, logic, bitwise, string, math, control flow, type ops'),
            ]),
          ]),
          tr([
            td([code([Component.text('std_collections')])]),
            td([Component.text('~43')]),
            td([Component.text('List and Map operations')]),
          ]),
          tr([
            td([code([Component.text('std_io')])]),
            td([Component.text('~10')]),
            td([Component.text('Console, process, time, random, environment')]),
          ]),
          tr([
            td([code([Component.text('std_memory')])]),
            td([Component.text('~30')]),
            td([Component.text('Linear memory (C/C++ interop)')]),
          ]),
          tr([
            td([code([Component.text('dart_std')])]),
            td([Component.text('~18')]),
            td([
              Component.text(
                  'Dart-specific: cascade, null_aware_access, invoke, spread'),
            ]),
          ]),
        ]),
      ]),
    ]);
  }

  Component _buildPackageRow(String name, String desc) {
    return div(classes: 'docs-package-row', [
      code(classes: 'docs-package-name', [Component.text(name)]),
      span(classes: 'docs-package-desc', [Component.text(' \u2014 $desc')]),
    ]);
  }

  Component _buildStdCategory(String name, String funcs) {
    return div(classes: 'docs-std-category', [
      strong(classes: 'docs-std-name', [Component.text(name)]),
      span(classes: 'docs-std-funcs', [Component.text(funcs)]),
    ]);
  }
}
