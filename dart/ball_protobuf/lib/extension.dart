/// Protobuf extension handles + a registry, for codegen.
///
/// Pure, Ball-portable value types (no `package:` imports — `dart:core` only).
/// An extension is wire-indistinguishable from a regular field of the same
/// number; the descriptor bridge folds each one into its extendee's field list
/// keyed by `[fully.qualified.name]` (bracketed, to avoid colliding with a
/// sibling field of the same simple name). These types give that the typed,
/// lookup-able surface generated code needs: an [Extension] handle per
/// `extend` field, and an [ExtensionRegistry] that finds extensions by
/// `(extendee, number)` and by Any type-url.
library;

/// A single protobuf extension field.
///
/// Mirrors the information the descriptor bridge records for an `extend` field:
/// the [extendeeFullName] it extends, its [number], its protobuf [type] (e.g.
/// `TYPE_STRING`, `TYPE_MESSAGE`), the bracketed [fieldKey] under which the
/// runtime stores its value in the extendee's backing map, and — for message
/// extensions — the embedded field [descriptor].
class Extension {
  /// Fully-qualified name of the extended message (stripped FQN, no leading
  /// dot), e.g. `acme.User`.
  final String extendeeFullName;

  /// The extension field's storage key in the extendee's backing map: the
  /// bracketed fully-qualified extension name, e.g. `[acme.user_email]`. This
  /// is the exact key the descriptor bridge writes.
  final String fieldKey;

  /// The extension's field number.
  final int number;

  /// The extension's protobuf type (e.g. `TYPE_STRING`, `TYPE_MESSAGE`).
  final String type;

  /// For a `TYPE_MESSAGE` extension, the embedded message's field descriptor
  /// list; `null` for scalar/enum extensions.
  final List<Map<String, Object?>>? descriptor;

  const Extension({
    required this.extendeeFullName,
    required this.fieldKey,
    required this.number,
    required this.type,
    this.descriptor,
  });

  /// The fully-qualified extension name without the surrounding brackets, e.g.
  /// `acme.user_email` for a [fieldKey] of `[acme.user_email]`.
  String get fullName => fieldKey.startsWith('[') && fieldKey.endsWith(']')
      ? fieldKey.substring(1, fieldKey.length - 1)
      : fieldKey;
}

/// A registry of [Extension]s, looked up by `(extendee, number)` and by
/// Any-style type-url.
///
/// Generated code emits one registry per file and merges them (via [merge]) for
/// option resolution and Any-in-JSON, mirroring protobuf-es's registry API and
/// protobuf-go's `protoregistry`.
class ExtensionRegistry {
  // extendeeFullName -> (number -> Extension)
  final Map<String, Map<int, Extension>> _byExtendeeNumber = {};
  // type-url (e.g. `type.googleapis.com/acme.user_email`) -> Extension
  final Map<String, Extension> _byTypeUrl = {};

  /// Creates an empty registry.
  ExtensionRegistry();

  /// Creates a registry pre-populated with [extensions].
  factory ExtensionRegistry.of(Iterable<Extension> extensions) {
    final r = ExtensionRegistry();
    for (final e in extensions) {
      r.register(e);
    }
    return r;
  }

  /// Registers [extension] for lookup by `(extendee, number)` and by type-url.
  void register(Extension extension) {
    (_byExtendeeNumber[extension.extendeeFullName] ??=
            <int, Extension>{})[extension.number] =
        extension;
    _byTypeUrl[_typeUrlFor(extension.fullName)] = extension;
  }

  /// Looks up an extension by its [extendeeFullName] and field [number], or
  /// `null` when none is registered.
  Extension? lookup(String extendeeFullName, int number) =>
      _byExtendeeNumber[extendeeFullName]?[number];

  /// Looks up an extension by Any-style [typeUrl] (the part after the final
  /// `/` is matched against the extension's fully-qualified name), or `null`
  /// when none is registered. A bare fully-qualified name is also accepted.
  Extension? lookupByTypeUrl(String typeUrl) {
    final direct = _byTypeUrl[typeUrl];
    if (direct != null) return direct;
    // Accept a bare FQN (no `host/` prefix) by canonicalizing to a type-url.
    return _byTypeUrl[_typeUrlFor(_typeNameOf(typeUrl))];
  }

  /// Merges [other] into this registry (entries from [other] win on conflict).
  void merge(ExtensionRegistry other) {
    for (final byNumber in other._byExtendeeNumber.values) {
      for (final ext in byNumber.values) {
        register(ext);
      }
    }
  }

  /// All registered extensions.
  Iterable<Extension> get extensions => _byTypeUrl.values;

  static String _typeNameOf(String typeUrl) {
    final slash = typeUrl.lastIndexOf('/');
    return slash >= 0 ? typeUrl.substring(slash + 1) : typeUrl;
  }

  static String _typeUrlFor(String fullName) => 'type.googleapis.com/$fullName';
}

/// Merges several [ExtensionRegistry]s into one (later registries win on
/// conflict), so a consumer can combine the per-file registries generated for
/// every `.proto` in scope.
ExtensionRegistry mergeRegistries(Iterable<ExtensionRegistry> registries) {
  final out = ExtensionRegistry();
  for (final r in registries) {
    out.merge(r);
  }
  return out;
}
