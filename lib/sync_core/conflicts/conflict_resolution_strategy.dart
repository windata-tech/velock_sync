/// User-chosen resolution methods supported by V1 dataset adapters.
///
/// Values are persisted by their stable wire name in the conflict-resolution
/// intent table; do not derive persistence from enum ordering.
enum ConflictResolutionStrategy {
  keepLocal('keep-local'),
  keepRemote('keep-remote'),
  keepBoth('keep-both'),
  openInVelock('open-in-velock');

  const ConflictResolutionStrategy(this.persistedValue);

  final String persistedValue;
}
