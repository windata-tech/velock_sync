/// Dataset implementations that can be reconstructed by the V1 profile
/// dispatcher. The persistent value is deliberately stable and never derived
/// from an enum name.
enum SyncDatasetKind {
  selectedFolder('selected-folder'),
  velockManaged('velock-managed'),

  /// Plain (unencrypted) folder mirror: one local folder bound to one remote
  /// folder. The remote side holds the user's real files under their real
  /// names; there is no vault, key material or recovery package.
  plainFolder('plain-folder');

  const SyncDatasetKind(this.persistedValue);

  final String persistedValue;

  static SyncDatasetKind? tryParse(Object? value) {
    if (value is! String) return null;
    for (final kind in values) {
      if (kind.persistedValue == value) return kind;
    }
    return null;
  }
}
