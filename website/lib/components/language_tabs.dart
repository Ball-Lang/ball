import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

@client
class LanguageTabs extends StatefulComponent {
  const LanguageTabs({
    required this.labels,
    required this.languages,
    required this.filenames,
    required this.codes,
    super.key,
  });

  /// Display labels for each tab (e.g., "Dart", "C++")
  final List<String> labels;

  /// Language identifiers for CSS classes (e.g., "dart", "cpp")
  final List<String> languages;

  /// Filenames displayed in code block headers
  final List<String> filenames;

  /// Code content for each tab
  final List<String> codes;

  @override
  State<LanguageTabs> createState() => _LanguageTabsState();
}

class _LanguageTabsState extends State<LanguageTabs> {
  int activeIndex = 0;

  @override
  Component build(BuildContext context) {
    return div([
      // Tab buttons (only if > 1 tab)
      if (component.labels.length > 1)
        div(classes: 'lang-tabs', [
          for (var i = 0; i < component.labels.length; i++)
            button(
              classes: 'lang-tab-btn${i == activeIndex ? ' active' : ''}',
              onClick: () => setState(() => activeIndex = i),
              [Component.text(component.labels[i])],
            ),
        ]),

      // Active code block
      div(classes: 'code-block', [
        div(classes: 'code-header', [
          span(classes: 'code-filename', [
            Component.text(component.filenames[activeIndex]),
          ]),
          span(classes: 'code-lang', [
            Component.text(component.languages[activeIndex]),
          ]),
        ]),
        pre(classes: 'code-pre', [
          Component.element(
            tag: 'code',
            classes:
                'code-content language-${component.languages[activeIndex]}',
            children: [Component.text(component.codes[activeIndex])],
          ),
        ]),
      ]),
    ]);
  }
}
