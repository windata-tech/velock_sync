import 'dart:io';

final _forbidden = <RegExp>[
  RegExp(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
  RegExp(r'\bAKIA[0-9A-Z]{16}\b'),
  RegExp(r'\bgh[pousr]_[A-Za-z0-9]{30,}\b'),
  RegExp(r'\bAIza[0-9A-Za-z_-]{35}\b'),
  RegExp(r'''(?i:authorization\s*[:=]\s*["']?bearer\s+[A-Za-z0-9._~-]{24,})'''),
];

const _ignoredDirectories = <String>{
  '.git',
  '.dart_tool',
  'build',
  '.idea',
  '.codegraph',
};

const _textExtensions = <String>{
  '.dart',
  '.kt',
  '.kts',
  '.swift',
  '.m',
  '.mm',
  '.java',
  '.xml',
  '.plist',
  '.yaml',
  '.yml',
  '.json',
  '.md',
  '.txt',
  '.gradle',
  '.properties',
  '.sh',
};

/// A deliberately conservative source-tree secret scan. It supplements, but
/// does not replace, protected release credentials and platform secret stores.
void main() {
  final violations = <String>[];
  for (final entity in Directory.current.listSync(recursive: true)) {
    if (entity is! File || !_isScannable(entity)) continue;
    final text = entity.readAsStringSync();
    for (var index = 0; index < _forbidden.length; index++) {
      if (_forbidden[index].hasMatch(text)) {
        violations.add('${entity.path} (rule ${index + 1})');
      }
    }
  }
  if (violations.isNotEmpty) {
    stderr.writeln('Potential secrets found:');
    for (final violation in violations) {
      stderr.writeln('- $violation');
    }
    exitCode = 1;
    return;
  }
  stdout.writeln('Source-tree secret scan passed.');
}

bool _isScannable(File file) {
  final segments = file.absolute.uri.pathSegments.toSet();
  if (segments.any(_ignoredDirectories.contains)) return false;
  final basename = file.uri.pathSegments.last;
  if (basename == 'LICENSE' || basename == 'Podfile') return true;
  return _textExtensions.any(basename.endsWith);
}
