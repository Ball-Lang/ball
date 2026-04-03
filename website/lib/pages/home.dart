import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/navbar.dart';
import '../components/footer.dart';
import '../components/feature_card.dart';
import '../components/code_block.dart';
import '../components/language_tabs.dart';

class HomePage extends StatelessComponent {
  const HomePage({super.key});

  @override
  Component build(BuildContext context) {
    return .fragment([
      const Navbar(),
      _buildHero(),
      _buildTrustedBy(),
      _buildFeatures(),
      _buildHowItWorks(),
      _buildCodeDemo(),
      _buildLanguageSupport(),
      _buildArchitecture(),
      _buildCta(),
      const Footer(),
    ]);
  }

  Component _buildHero() {
    return section(classes: 'hero', [
      div(classes: 'hero-bg-effects', [
        div(classes: 'hero-glow hero-glow-1', []),
        div(classes: 'hero-glow hero-glow-2', []),
        div(classes: 'hero-grid-bg', []),
      ]),
      div(classes: 'hero-content', [
        div(classes: 'hero-badge', [
          span(classes: 'hero-badge-dot', []),
          Component.text('Now with Dart & C++ implementations'),
        ]),
        h1(classes: 'hero-title', [
          span(classes: 'hero-title-line', [Component.text('Code is ')]),
          span(classes: 'hero-title-accent', [Component.text('Data')]),
        ]),
        p(classes: 'hero-subtitle', [
          Component.text(
            'Ball is a programming language where every program is a Protocol Buffer message. '
            'Write your logic once \u2014 serialize it, store it, send it over the wire, '
            'and compile it to any target language.',
          ),
        ]),
        div(classes: 'hero-actions', [
          a(
            href: '/docs',
            classes: 'btn btn-primary',
            [Component.text('Get Started')],
          ),
          a(
            href: '/examples',
            classes: 'btn btn-secondary',
            [Component.text('See Examples')],
          ),
          a(
            href: 'https://github.com/Ball-Lang/ball',
            classes: 'btn btn-ghost',
            attributes: {'target': '_blank', 'rel': 'noopener noreferrer'},
            [Component.text('View on GitHub \u2197')],
          ),
        ]),
        div(classes: 'hero-code-preview', [
          const CodeBlock(
            filename: 'hello_world.ball.json',
            language: 'json',
            code: '{\n'
                '  "name": "hello_world",\n'
                '  "entryModule": "main",\n'
                '  "entryFunction": "main",\n'
                '  "modules": [\n'
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
        ]),
      ]),
    ]);
  }

  Component _buildTrustedBy() {
    return section(classes: 'trusted-section', [
      div(classes: 'trusted-inner', [
        p(classes: 'trusted-label', [Component.text('POWERED BY')]),
        div(classes: 'trusted-logos', [
          span(classes: 'trusted-item', [Component.text('Protocol Buffers')]),
          span(classes: 'trusted-divider', [Component.text('\u00B7')]),
          span(classes: 'trusted-item', [Component.text('gRPC Patterns')]),
          span(classes: 'trusted-divider', [Component.text('\u00B7')]),
          span(classes: 'trusted-item', [Component.text('Buf Registry')]),
          span(classes: 'trusted-divider', [Component.text('\u00B7')]),
          span(classes: 'trusted-item', [Component.text('Cross-Platform')]),
        ]),
      ]),
    ]);
  }

  Component _buildFeatures() {
    return section(classes: 'features-section', id: 'features', [
      div(classes: 'section-inner', [
        div(classes: 'section-header', [
          span(classes: 'section-label', [Component.text('WHY BALL?')]),
          h2(classes: 'section-title', [Component.text('Language design, reimagined')]),
          p(classes: 'section-desc', [
            Component.text(
              'Ball takes a fundamentally different approach to programming languages. '
              'Instead of text files parsed into ASTs, your code starts as structured data.',
            ),
          ]),
        ]),
        div(classes: 'features-grid', [
          const FeatureCard(
            icon: '\u{1F4E6}',
            title: 'Code is Protobuf',
            description:
                'Every Ball program is a Protocol Buffer message. If it deserializes, '
                'it\u2019s structurally valid. No syntax errors, ever.',
          ),
          const FeatureCard(
            icon: '\u{1F310}',
            title: 'Compile Anywhere',
            description:
                'One Ball program compiles to Dart, C++, Python, Go, JavaScript, '
                'Java, C#, and more. Write once, target everything.',
          ),
          const FeatureCard(
            icon: '\u{1F4E1}',
            title: 'Send Code Over the Wire',
            description:
                'Programs are data. Serialize them to binary protobuf, store in databases, '
                'send over gRPC, or inspect programmatically.',
          ),
          const FeatureCard(
            icon: '\u26A1',
            title: 'Protobuf Type System',
            description:
                'Ball uses protobuf\u2019s own DescriptorProto types, already mapped to '
                'every language. No type system fragmentation.',
          ),
          const FeatureCard(
            icon: '\u{1F9E9}',
            title: 'One In, One Out',
            description:
                'Every function takes one input message and returns one output message, '
                'like gRPC. This isn\u2019t a limitation \u2014 it IS the design.',
          ),
          const FeatureCard(
            icon: '\u{1F504}',
            title: 'Round-Trip Fidelity',
            description:
                'Encode Dart or C++ to Ball, then compile back. Metadata preserves '
                'visibility, annotations, and cosmetic details for perfect round-trips.',
          ),
        ]),
      ]),
    ]);
  }

  Component _buildHowItWorks() {
    return section(classes: 'how-section', [
      div(classes: 'section-inner', [
        div(classes: 'section-header', [
          span(classes: 'section-label', [Component.text('HOW IT WORKS')]),
          h2(classes: 'section-title', [
            Component.text('Three programs, one language'),
          ]),
          p(classes: 'section-desc', [
            Component.text(
              'For each target language, Ball needs three components to achieve full support.',
            ),
          ]),
        ]),
        div(classes: 'how-grid', [
          _buildHowCard(
            '\u{1F4DD}',
            'Encoder',
            'Source \u2192 Ball',
            'Parses native source code (Dart, C++, etc.) and encodes it into '
                'Ball protobuf messages. The Dart encoder uses the analyzer package; '
                'the C++ encoder uses Clang\u2019s JSON AST.',
          ),
          _buildHowCard(
            '\u2699\uFE0F',
            'Compiler',
            'Ball \u2192 Source',
            'Generates native source code from Ball protobuf messages. Handles '
                'expression trees, base function dispatch, type emission, and '
                'lazy evaluation for control flow.',
          ),
          _buildHowCard(
            '\u25B6\uFE0F',
            'Engine',
            'Ball \u2192 Execution',
            'Interprets Ball programs directly at runtime without compilation. '
                'Evaluates expressions, manages scopes, and dispatches base functions '
                'to native implementations.',
          ),
        ]),
      ]),
    ]);
  }

  Component _buildHowCard(
    String icon,
    String title,
    String arrow,
    String desc,
  ) {
    return div(classes: 'how-card', [
      div(classes: 'how-card-icon', [Component.text(icon)]),
      h3(classes: 'how-card-title', [Component.text(title)]),
      span(classes: 'how-card-arrow', [Component.text(arrow)]),
      p(classes: 'how-card-desc', [Component.text(desc)]),
    ]);
  }

  Component _buildCodeDemo() {
    return section(classes: 'demo-section', [
      div(classes: 'section-inner', [
        div(classes: 'section-header', [
          span(classes: 'section-label', [Component.text('SEE IT IN ACTION')]),
          h2(classes: 'section-title', [
            Component.text('One program, many targets'),
          ]),
          p(classes: 'section-desc', [
            Component.text(
              'The same Ball program compiles to idiomatic code in each target language.',
            ),
          ]),
        ]),
        div(classes: 'demo-grid', [
          div(classes: 'demo-col', [
            const CodeBlock(
              filename: 'fibonacci.ball.json (simplified)',
              language: 'json',
              code: '// Ball expression tree (pseudo-JSON)\n'
                  '{\n'
                  '  "function": "fibonacci",\n'
                  '  "body": {\n'
                  '    "block": {\n'
                  '      "statements": [\n'
                  '        // if (n <= 1) return n\n'
                  '        { "call": {\n'
                  '            "function": "if",\n'
                  '            "input": {\n'
                  '              "condition": { "call": "lte(n, 1)" },\n'
                  '              "then": { "call": "return(n)" }\n'
                  '            }\n'
                  '        }}\n'
                  '      ],\n'
                  '      // return fib(n-1) + fib(n-2)\n'
                  '      "result": "add(fib(sub(n,1)), fib(sub(n,2)))"\n'
                  '    }\n'
                  '  }\n'
                  '}',
            ),
          ]),
          div(classes: 'demo-col', [
            LanguageTabs(
              labels: const ['Dart', 'C++'],
              languages: const ['dart', 'cpp'],
              filenames: const ['fibonacci.dart', 'fibonacci.cpp'],
              codes: const [
                '// Compiled to Dart\n'
                    'int fibonacci(int n) {\n'
                    '  if (n <= 1) return n;\n'
                    '  return fibonacci(n - 1)\n'
                    '       + fibonacci(n - 2);\n'
                    '}\n'
                    '\n'
                    'void main() {\n'
                    '  final result = fibonacci(10);\n'
                    '  print(result.toString());\n'
                    '}',
                '// Compiled to C++\n'
                    '#include <iostream>\n'
                    '\n'
                    'int fibonacci(int n) {\n'
                    '  if (n <= 1) return n;\n'
                    '  return fibonacci(n - 1)\n'
                    '       + fibonacci(n - 2);\n'
                    '}\n'
                    '\n'
                    'int main() {\n'
                    '  auto result = fibonacci(10);\n'
                    '  std::cout << std::to_string(result);\n'
                    '}',
              ],
            ),
          ]),
        ]),
      ]),
    ]);
  }

  Component _buildLanguageSupport() {
    return section(classes: 'lang-section', [
      div(classes: 'section-inner', [
        div(classes: 'section-header', [
          span(classes: 'section-label', [Component.text('LANGUAGE SUPPORT')]),
          h2(classes: 'section-title', [
            Component.text('Growing ecosystem'),
          ]),
          p(classes: 'section-desc', [
            Component.text('Ball targets multiple languages at different maturity levels.'),
          ]),
        ]),
        div(classes: 'lang-grid', [
          _buildLangCard('Dart', 'Mature', 'dart',
              'Full compiler, encoder, engine. 242 engine tests. Reference implementation.'),
          _buildLangCard('C++', 'Prototype', 'cpp',
              'Full compiler, encoder (Clang AST), engine. Actively developed.'),
          _buildLangCard('Go', 'Bindings', 'go',
              'Proto bindings generated. Compiler, encoder, and engine planned.'),
          _buildLangCard('Python', 'Bindings', 'python',
              'Proto bindings generated. Implementation in future roadmap.'),
          _buildLangCard('TypeScript', 'Bindings', 'ts',
              'Proto bindings generated. Web-first target language.'),
          _buildLangCard('Java', 'Bindings', 'java',
              'Proto bindings generated. Enterprise target language.'),
          _buildLangCard('C#', 'Bindings', 'csharp',
              'Proto bindings generated. .NET ecosystem target.'),
        ]),
      ]),
    ]);
  }

  Component _buildLangCard(
    String name,
    String status,
    String id,
    String desc,
  ) {
    final statusClass = switch (status) {
      'Mature' => 'status-mature',
      'Prototype' => 'status-prototype',
      _ => 'status-bindings',
    };
    return div(classes: 'lang-card', [
      div(classes: 'lang-card-header', [
        h3(classes: 'lang-card-name', [Component.text(name)]),
        span(classes: 'lang-status $statusClass', [Component.text(status)]),
      ]),
      p(classes: 'lang-card-desc', [Component.text(desc)]),
    ]);
  }

  Component _buildArchitecture() {
    return section(classes: 'arch-section', [
      div(classes: 'section-inner', [
        div(classes: 'section-header', [
          span(classes: 'section-label', [Component.text('ARCHITECTURE')]),
          h2(classes: 'section-title', [Component.text('The expression tree')]),
          p(classes: 'section-desc', [
            Component.text(
              'Every Ball computation is one of seven expression types. '
              'This uniform representation makes programs inspectable and transformable.',
            ),
          ]),
        ]),
        div(classes: 'expr-grid', [
          _buildExprCard('call', 'Function call',
              'Invoke any function: {module, function, input}'),
          _buildExprCard('literal', 'Constant value',
              'int, double, string, bool, bytes, or list literals'),
          _buildExprCard('reference', 'Variable reference',
              'Reference a bound name; "input" = function parameter'),
          _buildExprCard('fieldAccess', 'Field access',
              'Read a field from an object: {object, field}'),
          _buildExprCard('messageCreation', 'Construct message',
              'Build a protobuf message: {typeName, fields[]}'),
          _buildExprCard('block', 'Statement block',
              'Sequential let-bindings + result expression'),
          _buildExprCard('lambda', 'Anonymous function',
              'Closures and inline function definitions'),
        ]),
      ]),
    ]);
  }

  Component _buildExprCard(String name, String title, String desc) {
    return div(classes: 'expr-card', [
      code(classes: 'expr-name', [Component.text(name)]),
      h4(classes: 'expr-title', [Component.text(title)]),
      p(classes: 'expr-desc', [Component.text(desc)]),
    ]);
  }

  Component _buildCta() {
    return section(classes: 'cta-section', [
      div(classes: 'cta-inner', [
        div(classes: 'cta-glow', []),
        h2(classes: 'cta-title', [
          Component.text('Ready to rethink programming?'),
        ]),
        p(classes: 'cta-desc', [
          Component.text(
            'Ball is open source and actively developed. '
            'Get started with the Dart implementation today.',
          ),
        ]),
        div(classes: 'cta-actions', [
          a(
            href: '/docs',
            classes: 'btn btn-primary btn-lg',
            [Component.text('Read the Docs')],
          ),
          a(
            href: 'https://github.com/Ball-Lang/ball',
            classes: 'btn btn-secondary btn-lg',
            attributes: {'target': '_blank', 'rel': 'noopener noreferrer'},
            [Component.text('Star on GitHub')],
          ),
        ]),
        div(classes: 'cta-install', [
          const CodeBlock(
            language: 'bash',
            code: '# Clone and get started\n'
                'git clone https://github.com/Ball-Lang/ball.git\n'
                'cd ball/dart && dart pub get\n'
                'cd engine && dart test  # Run 242 tests\n'
                '\n'
                '# Compile an example\n'
                'cd ../compiler\n'
                'dart run bin/compile.dart ../../examples/hello_world.ball.json',
          ),
        ]),
      ]),
    ]);
  }
}
