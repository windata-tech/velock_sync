import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('app open platform contract', () {
    late String androidManifest;
    late String iosInfo;
    late String macosInfo;

    setUpAll(() {
      androidManifest = _readRepositoryFile(
        'android/app/src/main/AndroidManifest.xml',
      );
      iosInfo = _readRepositoryFile('ios/Runner/Info.plist');
      macosInfo = _readRepositoryFile('macos/Runner/Info.plist');
    });

    test('Android registers only app/open in a strict VIEW filter', () {
      final activity = _mainActivityBody(androidManifest);
      final filters = _elementBodies(activity, 'intent-filter');

      final appOpenFilters = filters.where((filter) {
        final data = _selfClosingElementAttributes(filter, 'data');
        return data.length == 1 &&
            data.single['android:scheme'] == 'velocksync' &&
            data.single['android:host'] == 'app' &&
            data.single['android:path'] == '/open';
      }).toList();

      expect(appOpenFilters, hasLength(1));
      final appOpenFilter = appOpenFilters.single;
      expect(
        _namedValues(appOpenFilter, 'action'),
        equals({'android.intent.action.VIEW'}),
      );
      expect(
        _namedValues(appOpenFilter, 'category'),
        equals({
          'android.intent.category.DEFAULT',
          'android.intent.category.BROWSABLE',
        }),
      );
      expect(
        _selfClosingElementAttributes(appOpenFilter, 'data'),
        equals([
          {
            'android:scheme': 'velocksync',
            'android:host': 'app',
            'android:path': '/open',
          },
        ]),
      );
    });

    test('Android keeps the OAuth callback address unchanged', () {
      final activity = _mainActivityBody(androidManifest);
      final filters = _elementBodies(activity, 'intent-filter');

      final oauthFilters = filters.where((filter) {
        final data = _selfClosingElementAttributes(filter, 'data');
        return data.length == 1 &&
            data.single['android:scheme'] == 'velocksync' &&
            data.single['android:host'] == 'oauth' &&
            data.single['android:path'] == '/callback';
      }).toList();

      expect(oauthFilters, hasLength(1));
      final oauthFilter = oauthFilters.single;
      expect(
        _namedValues(oauthFilter, 'action'),
        equals({'android.intent.action.VIEW'}),
      );
      expect(
        _namedValues(oauthFilter, 'category'),
        equals({
          'android.intent.category.DEFAULT',
          'android.intent.category.BROWSABLE',
        }),
      );
      expect(
        _selfClosingElementAttributes(oauthFilter, 'data'),
        equals([
          {
            'android:scheme': 'velocksync',
            'android:host': 'oauth',
            'android:path': '/callback',
          },
        ]),
      );
    });

    test('Android disables Flutter built-in deep-link routing', () {
      final activity = _mainActivityBody(androidManifest);
      final metadata = _selfClosingElementAttributes(activity, 'meta-data')
          .where(
            (attributes) =>
                attributes['android:name'] == 'flutter_deeplinking_enabled',
          )
          .toList();

      expect(metadata, hasLength(1));
      expect(
        metadata.single,
        equals({
          'android:name': 'flutter_deeplinking_enabled',
          'android:value': 'false',
        }),
      );
    });

    test('iOS keeps velocksync and disables Flutter built-in routing', () {
      final root = _plistRootBody(iosInfo);
      expect(
        _topLevelPlistValue(root, 'FlutterDeepLinkingEnabled'),
        equals('<false/>'),
      );

      final urlTypes = _topLevelPlistValue(root, 'CFBundleURLTypes');
      expect(urlTypes, isNotNull);
      expect(
        _stringArrayValues(urlTypes!, 'CFBundleURLSchemes'),
        contains('velocksync'),
      );
      expect(
        _stringValuesForKey(urlTypes, 'CFBundleURLName'),
        contains('tech.windata.velock.sync.oauth'),
      );
    });

    test('macOS declares velocksync without Flutter routing keys', () {
      final root = _plistRootBody(macosInfo);
      expect(_topLevelPlistValue(root, 'FlutterDeepLinkingEnabled'), isNull);

      final urlTypes = _topLevelPlistValue(root, 'CFBundleURLTypes');
      expect(urlTypes, isNotNull);
      expect(
        _stringArrayValues(urlTypes!, 'CFBundleURLSchemes'),
        contains('velocksync'),
      );
    });

    test('plist helper ignores nested keys with the same name', () {
      const rootBody =
          '<key>Container</key><dict>'
          '<key>Target</key><string>nested</string>'
          '</dict>'
          '<key>Target</key><string>top-level</string>';

      expect(
        _topLevelPlistValue(rootBody, 'Target'),
        equals('<string>top-level</string>'),
      );
    });
  });
}

String _readRepositoryFile(String relativePath) {
  final file = File(relativePath);
  expect(file.existsSync(), isTrue, reason: 'Missing $relativePath');
  return file.readAsStringSync();
}

String _mainActivityBody(String manifest) {
  final match = RegExp(
    r'<activity\b[^>]*android:name="\.MainActivity"[^>]*>([\s\S]*?)</activity>',
  ).firstMatch(manifest);
  expect(match, isNotNull, reason: 'MainActivity was not found');
  return match!.group(1)!;
}

List<String> _elementBodies(String source, String tag) {
  final pattern = RegExp('<$tag\\b[^>]*>([\\s\\S]*?)</$tag>');
  return pattern
      .allMatches(source)
      .map((match) => match.group(1)!)
      .toList(growable: false);
}

List<Map<String, String>> _selfClosingElementAttributes(
  String source,
  String tag,
) {
  final pattern = RegExp('<$tag\\b([^>]*)/>');
  return pattern
      .allMatches(source)
      .map((match) => _attributes(match.group(1)!))
      .toList(growable: false);
}

Set<String> _namedValues(String source, String tag) =>
    _selfClosingElementAttributes(source, tag)
        .map((attributes) => attributes['android:name'])
        .whereType<String>()
        .toSet();

Map<String, String> _attributes(String source) => {
  for (final match in RegExp(
    r'([A-Za-z_][A-Za-z0-9_:.-]*)="([^"]*)"',
  ).allMatches(source))
    match.group(1)!: match.group(2)!,
};

String _plistRootBody(String source) {
  final plistStart = source.indexOf('<plist');
  expect(plistStart, isNot(-1), reason: 'Plist root was not found');
  final rootStart = source.indexOf('<dict>', plistStart);
  expect(rootStart, isNot(-1), reason: 'Top-level plist dict was not found');
  final plistEnd = source.indexOf('</plist>', rootStart);
  expect(plistEnd, isNot(-1), reason: 'Plist closing tag was not found');
  final rootEnd = source.lastIndexOf('</dict>', plistEnd);
  expect(rootEnd, greaterThan(rootStart));
  return source.substring(rootStart + '<dict>'.length, rootEnd);
}

String? _topLevelPlistValue(String rootBody, String key) {
  var depth = 0;
  var cursor = 0;

  while (cursor < rootBody.length) {
    final tagStart = rootBody.indexOf('<', cursor);
    if (tagStart == -1) return null;
    final tagEnd = rootBody.indexOf('>', tagStart + 1);
    if (tagEnd == -1) return null;
    final tag = rootBody.substring(tagStart, tagEnd + 1);

    if (depth == 0 && tag == '<key>') {
      final keyEndStart = rootBody.indexOf('</key>', tagEnd + 1);
      if (keyEndStart == -1) return null;
      final keyEnd = keyEndStart + '</key>'.length;
      if (rootBody.substring(tagEnd + 1, keyEndStart) == key) {
        final valueStart = _skipWhitespace(rootBody, keyEnd);
        return _plistValueAt(rootBody, valueStart);
      }
      cursor = keyEnd;
      continue;
    }

    if (_isContainerOpenTag(tag)) {
      depth++;
    } else if (_isContainerCloseTag(tag)) {
      depth--;
    }
    cursor = tagEnd + 1;
  }

  return null;
}

Iterable<String> _plistValuesForKey(String source, String key) sync* {
  final keyTag = '<key>$key</key>';
  var cursor = 0;

  while (cursor < source.length) {
    final keyStart = source.indexOf(keyTag, cursor);
    if (keyStart == -1) return;
    final valueStart = _skipWhitespace(source, keyStart + keyTag.length);
    yield _plistValueAt(source, valueStart);
    cursor = valueStart + 1;
  }
}

Set<String> _stringArrayValues(String source, String key) {
  final values = <String>{};
  for (final value in _plistValuesForKey(source, key)) {
    if (!value.startsWith('<array>')) continue;
    values.addAll(
      RegExp(
        r'<string>([^<]*)</string>',
      ).allMatches(value).map((match) => match.group(1)!),
    );
  }
  return values;
}

Set<String> _stringValuesForKey(String source, String key) {
  const prefix = '<string>';
  const suffix = '</string>';
  return {
    for (final value in _plistValuesForKey(source, key))
      if (value.startsWith(prefix) && value.endsWith(suffix))
        value.substring(prefix.length, value.length - suffix.length),
  };
}

String _plistValueAt(String source, int start) {
  if (start >= source.length || source[start] != '<') {
    throw FormatException('Expected plist value at offset $start');
  }
  final tagEnd = source.indexOf('>', start + 1);
  if (tagEnd == -1) throw const FormatException('Unclosed plist tag');
  final tag = source.substring(start, tagEnd + 1);

  if (_isContainerOpenTag(tag)) {
    final end = _containerEnd(source, start);
    return source.substring(start, end);
  }
  if (tag.endsWith('/>')) return tag;

  final name = RegExp(r'^<([A-Za-z][A-Za-z0-9.-]*)').firstMatch(tag)?.group(1);
  if (name == null) throw FormatException('Unsupported plist tag $tag');
  final closeTag = '</$name>';
  final closeStart = source.indexOf(closeTag, tagEnd + 1);
  if (closeStart == -1) throw FormatException('Missing $closeTag');
  return source.substring(start, closeStart + closeTag.length);
}

int _containerEnd(String source, int start) {
  var depth = 0;
  var cursor = start;

  while (cursor < source.length) {
    final tagStart = source.indexOf('<', cursor);
    if (tagStart == -1) break;
    final tagEnd = source.indexOf('>', tagStart + 1);
    if (tagEnd == -1) break;
    final tag = source.substring(tagStart, tagEnd + 1);

    if (_isContainerOpenTag(tag)) {
      depth++;
    } else if (_isContainerCloseTag(tag)) {
      depth--;
      if (depth == 0) return tagEnd + 1;
    }
    cursor = tagEnd + 1;
  }

  throw const FormatException('Unclosed plist container');
}

bool _isContainerOpenTag(String tag) =>
    RegExp(r'^<(?:dict|array)(?:\s|>)').hasMatch(tag) && !tag.endsWith('/>');

bool _isContainerCloseTag(String tag) =>
    RegExp(r'^</(?:dict|array)\s*>$').hasMatch(tag);

int _skipWhitespace(String source, int offset) {
  var cursor = offset;
  while (cursor < source.length && source.codeUnitAt(cursor) <= 0x20) {
    cursor++;
  }
  return cursor;
}
