import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_router/jaspr_router.dart';

class Navbar extends StatelessComponent {
  const Navbar({super.key});

  @override
  Component build(BuildContext context) {
    return nav(classes: 'navbar', [
      div(classes: 'navbar-inner', [
        a(href: '/', classes: 'navbar-brand', [
          span(classes: 'brand-icon', [Component.text('\u{1F3D0}')]),
          span(classes: 'brand-text', [Component.text('Ball')]),
        ]),
        div(classes: 'navbar-links', [
          Link(to: '/', child: span([Component.text('Home')])),
          Link(to: '/docs', child: span([Component.text('Docs')])),
          Link(to: '/examples', child: span([Component.text('Examples')])),
          a(
            href: 'https://github.com/Ball-Lang/ball',
            attributes: {'target': '_blank', 'rel': 'noopener noreferrer'},
            classes: 'nav-github',
            [
              span([Component.text('GitHub')]),
              span(classes: 'nav-icon-external', [Component.text('\u2197')]),
            ],
          ),
        ]),
      ]),
    ]);
  }
}
