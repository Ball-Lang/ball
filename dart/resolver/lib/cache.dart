/// Content-addressable cache for resolved Ball modules.
///
/// Layout:
///   ~/.ball/cache/sha256/<first-2-hex>/<full-hex>.ball.bin
///
/// Atomic writes: write to temp file, then rename. This prevents
/// partial reads and cache poisoning.
library;

import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:path/path.dart' as p;

import 'integrity.dart';

class ContentAddressableCache {
  final String cacheDir;

  ContentAddressableCache({String? cacheDir})
      : cacheDir = cacheDir ?? _defaultCacheDir();

  static String _defaultCacheDir() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return p.join(home, '.ball', 'cache');
  }

  /// Look up a module by its integrity hash.
  /// Returns null if not in cache.
  Module? get(String integrity) {
    final path = _pathForHash(integrity);
    if (path == null) return null;
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      return Module.fromBuffer(file.readAsBytesSync());
    } catch (_) {
      return null;
    }
  }

  /// Store a module in the cache. Returns the integrity hash.
  String put(Module module) {
    final bytes = module.writeToBuffer();
    final hash = computeIntegrityFromBytes(bytes);
    final path = _pathForHash(hash);
    if (path == null) return hash;

    final file = File(path);
    if (file.existsSync()) return hash;

    file.parent.createSync(recursive: true);
    // Atomic write: temp file + rename.
    final temp = File('$path.tmp.${pid}');
    try {
      temp.writeAsBytesSync(bytes);
      temp.renameSync(path);
    } catch (_) {
      try {
        temp.deleteSync();
      } catch (_) {}
    }
    return hash;
  }

  /// Check if a hash exists in cache.
  bool has(String integrity) {
    final path = _pathForHash(integrity);
    if (path == null) return false;
    return File(path).existsSync();
  }

  String? _pathForHash(String integrity) {
    if (!integrity.startsWith('sha256:')) return null;
    final hex = integrity.substring(7);
    if (hex.length < 2) return null;
    return p.join(cacheDir, 'sha256', hex.substring(0, 2), '$hex.ball.bin');
  }
}
