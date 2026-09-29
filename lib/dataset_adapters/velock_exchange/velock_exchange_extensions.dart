/// Frozen rule for fields a later version adds to a v1 exchange object.
/// Kept identical in Sync and Velock.
///
/// Readers still require every v1 field and check its value, but a key they do
/// not know is an extension: its meaning is ignored, its bytes are not. A
/// signed object signs its v1 fields exactly as before, followed by the
/// extensions sorted by key (nested maps sorted too), so an older reader
/// verifies what a newer writer signed, and an object without extensions signs
/// the same bytes as it always did.
///
/// A field that restricts or changes what a v1 field means is not an extension:
/// it must bump the object's version so older readers reject it.
library;

/// The keys of [json] outside [known], canonicalized and sorted.
Map<String, Object?> exchangeExtensions(
  Map<String, dynamic> json,
  Set<String> known,
) {
  final keys = json.keys.where((key) => !known.contains(key)).toList()..sort();
  return Map.unmodifiable({for (final key in keys) key: _canonical(json[key])});
}

/// [v1] in its existing order, then [extensions] sorted by key.
Map<String, Object?> withExchangeExtensions(
  Map<String, Object?> v1,
  Map<String, Object?> extensions,
) {
  final result = <String, Object?>{...v1};
  for (final key in extensions.keys.toList()..sort()) {
    if (result.containsKey(key)) {
      throw FormatException('Extension $key shadows a v1 field.');
    }
    result[key] = _canonical(extensions[key]);
  }
  return result;
}

/// Throws when [json] lacks any of [required]; extra keys are allowed.
void requireExchangeKeys(
  Map<String, dynamic> json,
  Set<String> required,
  String name,
) {
  if (!json.keys.toSet().containsAll(required)) {
    throw FormatException('Velock Exchange $name schema is invalid.');
  }
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}
