/// Dataset implementations that can be reconstructed by the V1 profile
/// dispatcher. The persistent value is deliberately stable and never derived
/// from an enum name.
enum SyncDatasetKind {
  selectedFolder('selected-folder'),
  velockManaged('velock-managed');

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
