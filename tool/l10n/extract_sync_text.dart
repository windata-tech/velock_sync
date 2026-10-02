// Collects every syncText(context, zh, en) call (and the thin wrappers that
// forward to it) into tool/l10n/sync_strings.json, keyed by the English text.
// Interpolations become {0}, {1}… placeholders.
//
//   dart run tool/l10n/extract_sync_text.dart
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

const _callees = {'syncText', '_t', '_text', '_optionalSyncText', '_runLabel'};

class _Template {
  _Template(this.text, this.args);
  final String text;
  final List<String> args;
}

_Template? _template(Expression e) {
  if (e is SimpleStringLiteral) return _Template(e.value, const []);
  if (e is AdjacentStrings) {
    final parts = e.strings.map(_template).toList();
    if (parts.any((p) => p == null)) return null;
    final buffer = StringBuffer();
    final args = <String>[];
    for (final p in parts) {
      buffer.write(p!.text.replaceAllMapped(
          RegExp(r'\{(\d+)\}'), (m) => '{${int.parse(m[1]!) + args.length}}'));
      args.addAll(p.args);
    }
    return _Template(buffer.toString(), args);
  }
  if (e is StringInterpolation) {
    final buffer = StringBuffer();
    final args = <String>[];
    for (final element in e.elements) {
      if (element is InterpolationString) {
        buffer.write(element.value);
      } else if (element is InterpolationExpression) {
        buffer.write('{${args.length}}');
        args.add(element.expression.toSource());
      }
    }
    return _Template(buffer.toString(), args);
  }
  return null;
}

class _Visitor extends RecursiveAstVisitor<void> {
  _Visitor(this.path, this.unit, this.entries, this.problems);
  final String path;
  final CompilationUnit unit;
  final Map<String, Map<String, Object?>> entries;
  final List<String> problems;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.target == null &&
        _callees.contains(node.methodName.name) &&
        node.argumentList.arguments.length == 3) {
      final args = node.argumentList.arguments;
      final line = unit.lineInfo.getLocation(node.offset).lineNumber;
      final where = '$path:$line';
      final pairs = _branchPairs(args[1], args[2]);
      if (pairs != null) {
        for (final (zhBranch, enBranch) in pairs) {
          _record(where, zhBranch, enBranch);
        }
        super.visitMethodInvocation(node);
        return;
      }
      final zh = _template(args[1]);
      final en = _template(args[2]);
      if (zh == null || en == null) {
        // Parameters forwarded by the wrappers themselves are fine.
        if (!(args[1] is SimpleIdentifier && args[2] is SimpleIdentifier)) {
          problems.add('$where: non-literal text: ${args[2].toSource()}');
        }
      } else {
        _record(where, args[1], args[2]);
      }
    }
    super.visitMethodInvocation(node);
  }

  /// Splits `c ? a : b` (on both sides, same shape) into its branches.
  List<(Expression, Expression)>? _branchPairs(Expression zh, Expression en) {
    zh = zh.unParenthesized;
    en = en.unParenthesized;
    if (zh is ConditionalExpression && en is ConditionalExpression) {
      final a = _branchPairs(zh.thenExpression, en.thenExpression);
      final b = _branchPairs(zh.elseExpression, en.elseExpression);
      if (a == null || b == null) return null;
      return [...a, ...b];
    }
    if (_template(zh) != null && _template(en) != null) return [(zh, en)];
    if (en is ConditionalExpression) {
      // Only the English side branches: keep each English text, without a
      // matching Chinese one.
      final a = _branchPairs(zh, en.thenExpression);
      final b = _branchPairs(zh, en.elseExpression);
      if (a == null || b == null) return null;
      return [...a, ...b];
    }
    if (_template(en) != null) return [(zh, en)];
    return null;
  }

  void _record(String where, Expression zhExpr, Expression enExpr) {
    final zh = _template(zhExpr) ?? _Template('', const []);
    final en = _template(enExpr)!;
    {
        // Number the Chinese placeholders after the English ones.
        var zhText = zh.text;
        var ok = zh.text.isEmpty || zh.args.length == en.args.length;
        for (var i = 0; i < zh.args.length && ok; i++) {
          final j = en.args.indexOf(zh.args[i]);
          if (j < 0) {
            ok = false;
          } else {
            zhText = zhText.replaceFirst('{$i}', '\u0000$j\u0000');
          }
        }
        zhText = zhText.replaceAllMapped(
            RegExp('\u0000(\\d+)\u0000'), (m) => '{${m[1]}}');
        if (!ok) problems.add('$where: zh/en placeholders differ: ${zh.args} vs ${en.args}');
        for (final a in en.args) {
          final simple = RegExp(r'^[A-Za-z_][\w.!?()]*$').hasMatch(a);
          if (!simple) problems.add('$where: complex placeholder `$a` in "${en.text}"');
        }
        final entry = entries.putIfAbsent(en.text, () => {
              'zh': zhText,
              'args': en.args,
              'at': <String>[],
            });
        if (zhText.isEmpty) {
          (entry['at'] as List<String>).add(where);
          return;
        }
        entry['zh'] ??= zhText;
        if (entry['zh'] != zhText) {
          problems.add('$where: "${en.text}" has two Chinese texts: "${entry['zh']}" / "$zhText"');
        }
        (entry['at'] as List<String>).add(where);
        // Literal words inside a placeholder (e.g. `up ? 'Upload' : 'Download'`)
        // are looked up on their own at run time, so they need translating too.
        for (final arg in en.args) {
          for (final word in RegExp(r"'([^'{}$]+)'").allMatches(arg)) {
            final text = word[1]!;
            if (!RegExp('[A-Za-z]{2}').hasMatch(text)) continue;
            entries.putIfAbsent(text, () => {'zh': null, 'args': const <String>[], 'at': <String>[]});
            (entries[text]!['at'] as List<String>).add('$where (placeholder)');
          }
        }
    }
  }
}

void main() {
  final entries = <String, Map<String, Object?>>{};
  final problems = <String>[];
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final result = parseString(content: file.readAsStringSync(), path: file.path);
    result.unit.accept(_Visitor(file.path, result.unit, entries, problems));
  }
  final sorted = Map.fromEntries(
      entries.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  File('tool/l10n/sync_strings.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(sorted.map((k, v) =>
          MapEntry(k, {if (v['zh'] != null) 'zh': v['zh'], if ((v['args'] as List).isNotEmpty) 'args': v['args']}))));
  stdout.writeln('${entries.length} strings, '
      '${entries.values.where((v) => (v['args'] as List).isNotEmpty).length} with placeholders');
  for (final p in problems) {
    stdout.writeln(p);
  }
}
