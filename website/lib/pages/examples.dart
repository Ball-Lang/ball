import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/navbar.dart';
import '../components/footer.dart';
import '../components/code_block.dart';
import '../components/language_tabs.dart';

class ExamplesPage extends StatelessComponent {
  const ExamplesPage({super.key});

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
    return section(classes: 'examples-header', [
      div(classes: 'examples-header-inner', [
        span(classes: 'section-label', [Component.text('EXAMPLES')]),
        h1(classes: 'examples-title', [Component.text('Ball in Action')]),
        p(classes: 'examples-subtitle', [
          Component.text(
            'Explore real Ball programs and see how they compile to different target languages.',
          ),
        ]),
      ]),
    ]);
  }

  Component _buildContent() {
    return div(classes: 'examples-content', [
      div(classes: 'examples-inner', [
        // Hello World
        _buildExample(
          'Hello World',
          'The simplest Ball program \u2014 prints a message to the console using the std.print base function.',
          const CodeBlock(
            filename: 'hello_world.ball.json',
            language: 'json',
            code: '{\n'
                '  "name": "hello_world",\n'
                '  "entryModule": "main",\n'
                '  "entryFunction": "main",\n'
                '  "modules": [\n'
                '    {\n'
                '      "name": "std",\n'
                '      "functions": [\n'
                '        { "name": "print", "isBase": true }\n'
                '      ]\n'
                '    },\n'
                '    {\n'
                '      "name": "main",\n'
                '      "functions": [{\n'
                '        "name": "main",\n'
                '        "body": {\n'
                '          "call": {\n'
                '            "module": "std",\n'
                '            "function": "print",\n'
                '            "input": {\n'
                '              "messageCreation": {\n'
                '                "fields": [{\n'
                '                  "name": "message",\n'
                '                  "value": {\n'
                '                    "literal": {\n'
                '                      "stringValue": "Hello, World!"\n'
                '                    }\n'
                '                  }\n'
                '                }]\n'
                '              }\n'
                '            }\n'
                '          }\n'
                '        }\n'
                '      }]\n'
                '    }\n'
                '  ]\n'
                '}',
          ),
          [
            const CodeBlock(
              filename: 'Compiled \u2192 Dart',
              language: 'dart',
              code: 'void main() {\n'
                  '  print(\'Hello, World!\');\n'
                  '}',
            ),
            const CodeBlock(
              filename: 'Compiled \u2192 C++',
              language: 'cpp',
              code: '#include <iostream>\n'
                  '\n'
                  'int main() {\n'
                  '  std::cout << "Hello, World!" << std::endl;\n'
                  '  return 0;\n'
                  '}',
            ),
          ],
        ),

        // Fibonacci
        _buildExample(
          'Fibonacci',
          'A recursive Fibonacci implementation demonstrating control flow (if), '
              'comparison (lte), arithmetic (add, subtract), and function recursion.',
          const CodeBlock(
            filename: 'fibonacci.ball.json (simplified)',
            language: 'json',
            code: '// Functions: fibonacci(n) and main()\n'
                '// fibonacci uses:\n'
                '//   std.if     - branching (lazy evaluation)\n'
                '//   std.lte    - comparison (n <= 1)\n'
                '//   std.return - early return\n'
                '//   std.add    - addition\n'
                '//   std.subtract - subtraction\n'
                '// \n'
                '// The expression tree encodes:\n'
                '//   if (n <= 1) return n;\n'
                '//   return fibonacci(n-1) + fibonacci(n-2);\n'
                '//\n'
                '// All control flow is function calls \u2014\n'
                '// std.if is a base function that receives\n'
                '// condition, then, and else as lazy expressions.',
          ),
          [
            const CodeBlock(
              filename: 'Compiled \u2192 Dart',
              language: 'dart',
              code: 'int fibonacci(int n) {\n'
                  '  if (n <= 1) return n;\n'
                  '  return fibonacci(n - 1) + fibonacci(n - 2);\n'
                  '}\n'
                  '\n'
                  'void main() {\n'
                  '  final result = fibonacci(10);\n'
                  '  print(result.toString());\n'
                  '}',
            ),
            const CodeBlock(
              filename: 'Compiled \u2192 C++',
              language: 'cpp',
              code: '#include <iostream>\n'
                  '#include <string>\n'
                  '\n'
                  'int fibonacci(int n) {\n'
                  '  if (n <= 1) return n;\n'
                  '  return fibonacci(n - 1) + fibonacci(n - 2);\n'
                  '}\n'
                  '\n'
                  'int main() {\n'
                  '  auto result = fibonacci(10);\n'
                  '  std::cout << std::to_string(result);\n'
                  '  return 0;\n'
                  '}',
            ),
          ],
        ),

        // Comprehensive
        _buildExample(
          'Comprehensive Example',
          'A larger example demonstrating variables, string operations, lists, '
              'conditionals, loops, math functions, type checking, and more.',
          const CodeBlock(
            filename: 'comprehensive.ball.json (excerpt)',
            language: 'json',
            code: '// This example demonstrates:\n'
                '//\n'
                '// \u2022 Variable declarations (let-bindings)\n'
                '//   - final, var, const semantics via metadata\n'
                '//\n'
                '// \u2022 String operations\n'
                '//   - string_length, string_to_upper, string_contains\n'
                '//   - string_substring, string_replace, string_split\n'
                '//\n'
                '// \u2022 Math functions\n'
                '//   - math_sqrt, math_pow, math_abs, math_max\n'
                '//\n'
                '// \u2022 Collections (std_collections module)\n'
                '//   - list_add, list_length, list_map, list_where\n'
                '//   - map_put, map_get, map_contains_key\n'
                '//\n'
                '// \u2022 Control flow (all are function calls)\n'
                '//   - if/else, for, for_in, while, switch\n'
                '//\n'
                '// \u2022 Type operations\n'
                '//   - is, as type checking and casting',
          ),
          [
            const CodeBlock(
              filename: 'Compiled \u2192 Dart (excerpt)',
              language: 'dart',
              code: 'void main() {\n'
                  '  // Variables\n'
                  '  final greeting = \'Hello, Ball!\';\n'
                  '  var counter = 0;\n'
                  '  const pi = 3.14159;\n'
                  '\n'
                  '  // String ops\n'
                  '  final len = greeting.length;\n'
                  '  final upper = greeting.toUpperCase();\n'
                  '  final hasHello = greeting.contains(\'Hello\');\n'
                  '\n'
                  '  // Math\n'
                  '  final root = sqrt(144.0);\n'
                  '  final power = pow(2, 10);\n'
                  '\n'
                  '  // Collections\n'
                  '  final numbers = [1, 2, 3, 4, 5];\n'
                  '  final doubled = numbers.map((n) => n * 2);\n'
                  '  final evens = numbers.where((n) => n % 2 == 0);\n'
                  '\n'
                  '  // Control flow\n'
                  '  if (counter == 0) {\n'
                  '    print(\'Counter is zero\');\n'
                  '  }\n'
                  '  for (var i = 0; i < 5; i++) {\n'
                  '    counter += i;\n'
                  '  }\n'
                  '}',
            ),
          ],
        ),

        // Running examples
        section(classes: 'examples-run', [
          h2(classes: 'examples-run-title', [Component.text('Try it yourself')]),
          p(classes: 'docs-text', [
            Component.text('All examples are in the '),
            code([Component.text('examples/')]),
            Component.text(' directory of the repository:'),
          ]),
          const CodeBlock(
            language: 'bash',
            code: '# List available examples\n'
                'ls examples/\n'
                '# \u2192 all_constructs/  comprehensive/  fibonacci/  hello_world/\n'
                '\n'
                '# Compile any example to Dart\n'
                'cd dart/compiler\n'
                'dart run bin/compile.dart \\\n'
                '  ../../examples/fibonacci/fibonacci.ball.json\n'
                '\n'
                '# Run with the Ball engine (interpreter)\n'
                'cd ../engine\n'
                'dart run bin/run.dart \\\n'
                '  ../../examples/hello_world/hello_world.ball.json\n'
                '\n'
                '# Encode Dart source to Ball\n'
                'cd ../encoder\n'
                'dart run bin/encode.dart some_file.dart',
          ),
        ]),
      ]),
    ]);
  }

  Component _buildExample(
    String title,
    String description,
    CodeBlock ballCode,
    List<CodeBlock> compiledOutputs,
  ) {
    // Map language identifiers to display labels
    String langLabel(String lang) => switch (lang) {
      'dart' => 'Dart',
      'cpp' => 'C++',
      'python' => 'Python',
      'go' => 'Go',
      'typescript' => 'TypeScript',
      'java' => 'Java',
      'csharp' => 'C#',
      _ => lang.toUpperCase(),
    };

    return section(classes: 'example-item', [
      h2(classes: 'example-title', [Component.text(title)]),
      p(classes: 'example-desc', [Component.text(description)]),
      div(classes: 'example-grid', [
        div(classes: 'example-col', [
          h3(classes: 'example-col-label', [Component.text('Ball Program')]),
          ballCode,
        ]),
        div(classes: 'example-col', [
          h3(classes: 'example-col-label', [Component.text('Compiled Output')]),
          LanguageTabs(
            labels: compiledOutputs.map((b) => langLabel(b.language)).toList(),
            languages: compiledOutputs.map((b) => b.language).toList(),
            filenames: compiledOutputs.map((b) => b.filename ?? '').toList(),
            codes: compiledOutputs.map((b) => b.code).toList(),
          ),
        ]),
      ]),
    ]);
  }
}
