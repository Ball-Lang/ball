import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

class Footer extends StatelessComponent {
  const Footer({super.key});

  @override
  Component build(BuildContext context) {
    return footer(classes: 'site-footer', [
      div(classes: 'footer-inner', [
        div(classes: 'footer-grid', [
          // Brand column
          div(classes: 'footer-col', [
            div(classes: 'footer-brand', [
              span(classes: 'footer-brand-icon', [Component.text('\u{1F3D0}')]),
              span(classes: 'footer-brand-text', [Component.text('Ball')]),
            ]),
            p(classes: 'footer-tagline', [
              Component.text('Code is Data. Every program is a protobuf message.'),
            ]),
          ]),
          // Links column
          div(classes: 'footer-col', [
            h4(classes: 'footer-heading', [Component.text('Resources')]),
            ul(classes: 'footer-links', [
              li([a(href: '/docs', [Component.text('Documentation')])]),
              li([a(href: '/examples', [Component.text('Examples')])]),
              li([
                a(
                  href: 'https://github.com/AhmedNF/ball',
                  attributes: {
                    'target': '_blank',
                    'rel': 'noopener noreferrer',
                  },
                  [Component.text('GitHub')],
                ),
              ]),
            ]),
          ]),
          // Languages column
          div(classes: 'footer-col', [
            h4(classes: 'footer-heading', [Component.text('Languages')]),
            ul(classes: 'footer-links', [
              li([Component.text('Dart (mature)')]),
              li([Component.text('C++ (prototype)')]),
              li([Component.text('Go, Python, TypeScript')]),
              li([Component.text('Java, C#')]),
            ]),
          ]),
          // Community column
          div(classes: 'footer-col', [
            h4(classes: 'footer-heading', [Component.text('Project')]),
            ul(classes: 'footer-links', [
              li([
                a(
                  href: 'https://buf.build/ball-lang/ball',
                  attributes: {
                    'target': '_blank',
                    'rel': 'noopener noreferrer',
                  },
                  [Component.text('Buf Registry')],
                ),
              ]),
              li([Component.text('MIT License')]),
            ]),
          ]),
        ]),
        div(classes: 'footer-bottom', [
          p(classes: 'footer-copy', [
            Component.text('\u00A9 2024\u20132026 Ball Project. Built with '),
            a(
              href: 'https://jaspr.site',
              attributes: {
                'target': '_blank',
                'rel': 'noopener noreferrer',
              },
              [Component.text('Jaspr')],
            ),
            Component.text('.'),
          ]),
        ]),
      ]),
    ]);
  }
}
