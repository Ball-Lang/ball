import 'package:jaspr/dom.dart';
import 'package:jaspr/server.dart';
import 'package:jaspr_router/jaspr_router.dart';

import 'main.server.options.dart';
import 'pages/home.dart';
import 'pages/docs.dart';
import 'pages/examples.dart';

void main() {
  Jaspr.initializeApp(options: defaultServerOptions);

  runApp(
    Document(
      title: 'Ball - Code is Data',
      lang: 'en',
      meta: {
        'description':
            'Ball is a programming language where every program is a Protocol Buffer message. Write once, compile to any language.',
        'keywords':
            'ball, programming language, protobuf, protocol buffers, code is data, cross-platform, compiler',
        'og:title': 'Ball - Code is Data',
        'og:description':
            'A revolutionary programming language where every program is a structured protobuf message.',
        'og:type': 'website',
        'og:url': 'https://ball-lang.dev',
        'twitter:card': 'summary_large_image',
        'twitter:title': 'Ball - Code is Data',
        'twitter:description':
            'A revolutionary programming language where every program is a structured protobuf message.',
        'theme-color': '#6C3CE9',
      },
      head: [
        link(
          rel: 'preconnect',
          href: 'https://fonts.googleapis.com',
        ),
        link(
          rel: 'preconnect',
          href: 'https://fonts.gstatic.com',
          attributes: {'crossorigin': ''},
        ),
        link(
          rel: 'stylesheet',
          href:
              'https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800;900&family=JetBrains+Mono:wght@400;500;600&display=swap',
        ),
        link(rel: 'stylesheet', href: '/styles.css'),
        link(rel: 'manifest', href: '/manifest.json'),
      ],
      body: App(),
    ),
  );
}

class App extends StatelessComponent {
  const App({super.key});

  @override
  Component build(BuildContext context) {
    return Router(
      routes: [
        Route(path: '/', builder: (context, state) => const HomePage()),
        Route(path: '/docs', builder: (context, state) => const DocsPage()),
        Route(
          path: '/examples',
          builder: (context, state) => const ExamplesPage(),
        ),
      ],
    );
  }
}
