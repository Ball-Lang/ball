import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

class CodeBlock extends StatelessComponent {
  const CodeBlock({
    required this.code,
    required this.language,
    this.filename,
    super.key,
  });

  final String code;
  final String language;
  final String? filename;

  @override
  Component build(BuildContext context) {
    return div(classes: 'code-block', [
      if (filename != null)
        div(classes: 'code-header', [
          span(classes: 'code-filename', [Component.text(filename!)]),
          span(classes: 'code-lang', [Component.text(language)]),
        ]),
      pre(classes: 'code-pre', [
        Component.element(
          tag: 'code',
          classes: 'code-content language-$language',
          children: [Component.text(code)],
        ),
      ]),
    ]);
  }
}
