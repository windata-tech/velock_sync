/// An in-memory folder tree shared by the folder-tree cloud fakes (OneDrive,
/// Aliyun Drive, Google Drive): items have an ID, a name, a parent and, for
/// files, bytes.
class CloudTreeNode {
  CloudTreeNode({
    required this.id,
    required this.name,
    required this.parentId,
    this.bytes,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.utc(2030, 1, 1, 12);

  final String id;
  String name;
  String? parentId;

  /// Null for a folder.
  List<int>? bytes;
  DateTime updatedAt;
  int version = 1;

  /// A provider-specific type, e.g. a Google Doc; null for plain items.
  String? mimeType;

  bool get isFolder => bytes == null;
}

class CloudTree {
  CloudTree({required this.rootId}) {
    _nodes[rootId] = CloudTreeNode(id: rootId, name: '', parentId: null);
  }

  final String rootId;
  final _nodes = <String, CloudTreeNode>{};
  int _nextId = 0;

  /// Items moved to the recycle bin, as path strings, in order.
  final recycled = <String>[];

  CloudTreeNode? byId(String id) => _nodes[id];

  List<CloudTreeNode> childrenOf(String id) =>
      _nodes.values.where((node) => node.parentId == id).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  CloudTreeNode? child(String parentId, String name) {
    for (final node in _nodes.values) {
      if (node.parentId == parentId && node.name == name) return node;
    }
    return null;
  }

  /// Resolves [segments] below [fromId]; null when any part is missing.
  CloudTreeNode? resolve(List<String> segments, {String? fromId}) {
    var current = _nodes[fromId ?? rootId];
    for (final segment in segments) {
      if (current == null || !current.isFolder) return null;
      current = child(current.id, segment);
    }
    return current;
  }

  String pathOf(CloudTreeNode node) {
    final names = <String>[];
    CloudTreeNode? current = node;
    while (current != null && current.id != rootId) {
      names.insert(0, current.name);
      current = current.parentId == null ? null : _nodes[current.parentId];
    }
    return '/${names.join('/')}';
  }

  CloudTreeNode add(String parentId, String name, {List<int>? bytes}) {
    final node = CloudTreeNode(
      id: 'item-${_nextId++}',
      name: name,
      parentId: parentId,
      bytes: bytes,
    );
    _nodes[node.id] = node;
    return node;
  }

  /// Creates every missing folder of [segments] below [fromId].
  CloudTreeNode ensureFolders(List<String> segments, {String? fromId}) {
    var current = _nodes[fromId ?? rootId]!;
    for (final segment in segments) {
      current = child(current.id, segment) ?? add(current.id, segment);
    }
    return current;
  }

  /// Writes a file at [path] (relative to [fromId]), creating its folders.
  CloudTreeNode writeFile(String path, List<int> bytes, {String? fromId}) {
    final segments = path.split('/');
    final parent = ensureFolders(
      segments.sublist(0, segments.length - 1),
      fromId: fromId,
    );
    final existing = child(parent.id, segments.last);
    if (existing != null) {
      existing
        ..bytes = bytes
        ..version += 1;
      return existing;
    }
    return add(parent.id, segments.last, bytes: bytes);
  }

  void remove(CloudTreeNode node, {required bool toRecycleBin}) {
    if (toRecycleBin) recycled.add(pathOf(node));
    for (final child in childrenOf(node.id)) {
      remove(child, toRecycleBin: false);
    }
    _nodes.remove(node.id);
  }

  void clear() {
    _nodes.removeWhere((id, _) => id != rootId);
    recycled.clear();
  }

  Iterable<CloudTreeNode> get all => _nodes.values;
}
