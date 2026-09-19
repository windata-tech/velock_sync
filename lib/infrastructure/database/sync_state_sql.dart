/// Shared SQL value conversions for the sync state database.
///
/// Internal to `lib/infrastructure/database`: every query module converts
/// storage primitives through these helpers so NULL handling stays uniform.
library;

/// `null`-safe millisecond timestamp to UTC [DateTime].
DateTime? dateFromMillis(int? value) => value == null
    ? null
    : DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);

/// `null`-safe millisecond integer to [Duration].
Duration? durationFromMillis(int? value) =>
    value == null ? null : Duration(milliseconds: value);

/// `null`-safe SQLite 0/1 flag to [bool].
bool? boolFromSql(int? value) => value == null ? null : value != 0;
