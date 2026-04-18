# ball_resolver

Module resolver for the [Ball programming language](https://ball-lang.dev).

`ball_resolver` fetches, verifies, and caches Ball modules from a variety of sources -- HTTP URLs, local files, git repositories, inline literals, and language-specific package registries. All downloads are content-addressable and verified with SHA-256 integrity hashes.

## Install

```
dart pub add ball_resolver
```

## Quick start

```dart
import 'package:ball_resolver/ball_resolver.dart';

Future<void> main() async {
  final resolver = ModuleResolver();

  // Resolve an import declared inside a Ball program.
  final module = await resolver.resolve(someModuleImport);

  print('Resolved ${module.name} with ${module.functions.length} functions');
}
```

## Supported sources

| Scheme | Example |
|--------|---------|
| HTTP(S) | `https://example.com/my_module.ball.json` |
| File | `file:///abs/path/to/module.ball.json` |
| Git | `git://github.com/user/repo.git#v1.2.3` |
| Inline | `inline:<base64-encoded-module>` |
| Registry (pub) | `pub:package_name@^1.0.0` |
| Registry (npm) | `npm:@scope/pkg@1.0.0` |
| Registry (nuget, cargo, pypi, maven) | via `RegistryBridge` |

## Features

- **Integrity verification**: every resolved module is hashed and compared against the import's declared SHA-256.
- **Content-addressable cache**: identical modules are stored once, keyed by their integrity hash.
- **Registry adapters**: pluggable adapters for pub, npm, and a generic `RegistryBridge` that handles nuget, cargo, pypi, and maven.
- **Recursive resolution**: `resolver.resolveAll(program)` inlines every transitive import into a self-contained `Program`.

## API at a glance

| Symbol | Purpose |
|--------|---------|
| `ModuleResolver` | Top-level entry point; resolves any `ModuleImport` |
| `ContentAddressableCache` | Local cache keyed by integrity hash |
| `computeIntegrity`, `verifyIntegrity` | SHA-256 helpers |
| `PubAdapter`, `NpmAdapter`, `RegistryBridge` | Registry-specific fetchers |

## Links

- Website: https://ball-lang.dev
- Repository: https://github.com/ball-lang/ball
- Issue tracker: https://github.com/ball-lang/ball/issues

## License

MIT
