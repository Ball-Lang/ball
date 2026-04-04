import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/navbar.dart';
import '../components/footer.dart';
import '../components/code_block.dart';
import '../components/language_tabs.dart';
import '../generated/examples.dart' as examples;

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
          CodeBlock(
            filename: 'hello_world.ball.json',
            language: 'json',
            code: examples.helloWorldBallJson,
          ),
          [
            CodeBlock(
              filename: 'Compiled \u2192 Dart',
              language: 'dart',
              code: examples.helloWorldCompiledDart,
            ),
            CodeBlock(
              filename: 'Compiled \u2192 C++',
              language: 'cpp',
              code: examples.helloWorldCompiledCpp,
            ),
          ],
        ),

        // Fibonacci
        _buildExample(
          'Fibonacci',
          'A recursive Fibonacci implementation demonstrating control flow (if), '
              'comparison (lte), arithmetic (add, subtract), and function recursion.',
          CodeBlock(
            filename: 'fibonacci.ball.json',
            language: 'json',
            code: examples.fibonacciBallJson,
          ),
          [
            CodeBlock(
              filename: 'Compiled \u2192 Dart',
              language: 'dart',
              code: examples.fibonacciCompiledDart,
            ),
            CodeBlock(
              filename: 'Compiled \u2192 C++',
              language: 'cpp',
              code: examples.fibonacciCompiledCpp,
            ),
          ],
        ),

        // Comprehensive
        _buildExample(
          'Comprehensive Example',
          'A larger example demonstrating variables, string operations, lists, '
              'conditionals, loops, math functions, type checking, and more.',
          const CodeBlock(
            filename: 'comprehensive.ball.json',
            language: 'json',
            code: '// The comprehensive example is 7000+ lines of Ball JSON.\n'
                '// It demonstrates:\n'
                '//   \u2022 Type definitions (class, enum, mixin, typedef)\n'
                '//   \u2022 Inheritance and mixins\n'
                '//   \u2022 String and math operations\n'
                '//   \u2022 Collections (list, map)\n'
                '//   \u2022 Control flow (if, for, while, switch)\n'
                '//   \u2022 Type checking and casting\n'
                '//\n'
                '// View the full file on GitHub:\n'
                '// github.com/Ball-Lang/ball/blob/main/examples/\n'
                '//   comprehensive/comprehensive.ball.json',
          ),
          [
            CodeBlock(
              filename: 'Compiled \u2192 Dart (excerpt)',
              language: 'dart',
              code: examples.comprehensiveCompiledDartExcerpt,
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
