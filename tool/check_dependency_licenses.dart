import 'dart:convert';
import 'dart:io';

const _licenseNames = <String>[
  'LICENSE',
  'LICENSE.md',
  'LICENSE.txt',
  'COPYING',
  'COPYING.md',
  'COPYING.txt',
];

/// Fails CI when a resolved third-party Dart/Flutter package has no bundled
/// licence file. This is intentionally a deterministic admission gate; legal
/// review still decides whether a present licence is acceptable for release.
void main() {
  final configFile = File('.dart_tool/package_config.json');
  if (!configFile.existsSync()) {
    stderr.writeln(
      'Missing .dart_tool/package_config.json; run flutter pub get.',
    );
    exitCode = 2;
    return;
  }
  final config =
      jsonDecode(configFile.readAsStringSync()) as Map<String, Object?>;
  final packages = config['packages'] as List<Object?>?;
  if (packages == null) {
    stderr.writeln('package_config.json does not contain packages.');
    exitCode = 2;
    return;
  }

  final configUri = configFile.absolute.uri;
  final missing = <String>[];
  for (final raw in packages) {
    final package = raw as Map<String, Object?>;
    final name = package['name'] as String?;
    final rootUri = package['rootUri'] as String?;
    if (name == null || rootUri == null || name == 'velock_sync') continue;
    final root = Directory.fromUri(configUri.resolve(rootUri));
    if (!root.existsSync()) continue;
    if (!_hasBundledLicense(root)) {
      missing.add(name);
    }
  }

  if (missing.isNotEmpty) {
    stderr.writeln('Resolved packages without a bundled licence file:');
    for (final name in missing..sort()) {
      stderr.writeln('- $name');
    }
    exitCode = 1;
    return;
  }
  stdout.writeln('Dependency licence presence check passed.');
}

bool _hasBundledLicense(Directory root) {
  var current = root;
  // Flutter SDK packages share the SDK-level LICENSE. Pub-cache packages are
  // still required to provide a package-local license because no cache parent
  // carries one.
  for (var depth = 0; depth < 5; depth++) {
    if (_licenseNames.any(
      (file) => File('${current.path}/$file').existsSync(),
    )) {
      return true;
    }
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  return false;
}
