import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

class FeatureCard extends StatelessComponent {
  const FeatureCard({
    required this.icon,
    required this.title,
    required this.description,
    super.key,
  });

  final String icon;
  final String title;
  final String description;

  @override
  Component build(BuildContext context) {
    return div(classes: 'feature-card', [
      div(classes: 'feature-icon', [Component.text(icon)]),
      h3(classes: 'feature-title', [Component.text(title)]),
      p(classes: 'feature-desc', [Component.text(description)]),
    ]);
  }
}
