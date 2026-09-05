import 'dart:io';

import 'package:dio/dio.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

import '../model/connection_model.dart';
import '../model/protocol_model.dart';

part '../../../generated/features/connection/state/files_provider.g.dart';

@riverpod
class RemoteFileBrowser extends _$RemoteFileBrowser {
  String _currentPath = '/';

  bool get canGoBack => _currentPath != _currentRootPath;

  CancelToken? cancelToken;

  final List<FileBrowserState> _unstableStack = List.empty(growable: true);

  Future<WebdavClient> _client() async {
    final protocol = connectionModel.protocol;
    if (protocol is! WebDavProtocolModel) {
      throw UnsupportedError('Remote file browsing is currently WebDAV-only.');
    }
    final password = await ref
        .read(connectionRepositoryProvider)
        .readWebDavPassword(protocol.credentialRef);
    if (protocol.username?.isNotEmpty == true && password?.isNotEmpty == true) {
      return WebdavClient.basicAuth(
        url: '${protocol.address}:${protocol.port}',
        user: protocol.username!,
        pwd: password!,
      );
    }
    return WebdavClient.noAuth(url: '${protocol.address}:${protocol.port}');
  }

  @override
  FutureOr<FileBrowserState> build({
    required ConnectionModel connectionModel,
  }) async {
    final protocol = connectionModel.protocol;
    if (protocol is! WebDavProtocolModel) {
      throw UnsupportedError('Remote file browsing is currently WebDAV-only.');
    }
    _currentPath = _normalisePath(protocol.path ?? '/');
    return _fetchState(_currentPath);
  }

  /// 获取文件列表
  Future<FileBrowserState> _fetchState(String path) async {
    // 规范化输入路径
    path = _normalisePath(path);
    final files = await (await _client()).readDir(path);
    final fileBrowserState = FileBrowserState(
      path: path,
      rootPath: _currentRootPath,
      files: files,
    );

    // 只保留当前路径和父路径之上的
    _unstableStack.removeWhere(
      (e) => path == e.path || p.isWithin(path, e.path),
    );
    // 缓存到stack里，方便返回
    _unstableStack.add(fileBrowserState);
    printCurrentStack();
    return fileBrowserState;
  }

  /// 去到具体的页面
  Future<void> go(String path) async {
    state = const AsyncValue.loading();

    state = await AsyncValue.guard(() async {
      final newState = await _fetchState(path);
      logger.d('Remote browser navigated.');
      return newState;
    });
  }

  /// 返回上一级目录
  Future<void> goBack() async {
    final currentState = state.value;
    if (currentState == null || currentState.isRoot) return;

    final parentPath = p.dirname(currentState.path);
    // 优先从历史里取数据，而不是重新请求
    final stackState = _unstableStack
        .where((e) => e.path == parentPath)
        .singleOrNull;
    if (stackState != null) {
      state = AsyncValue.data(stackState);
      // 从历史栈移除当前这个没用的
      _unstableStack.removeLast();
    } else {
      logger.w('Remote browser history did not contain the parent directory.');
      await go(parentPath);
    }
    printCurrentStack();
  }

  /// 下载文件，因为文件在服务器呢，本地要打开只能先下载
  /// 不过，这里没处理大文件情况（目前来说，UI也还没有下载进度的回调）
  Future<File> downloadFile(
    String path, {
    required String ext,
    void Function(int count, int total)? onProgress,
  }) async {
    File tempFile = await createTempFile(fileExtension: ext);
    cancelToken?.cancel();
    cancelToken = CancelToken();
    await (await _client()).readFile(
      path,
      tempFile.path,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
    if (tempFile.existsSync()) {
      return tempFile;
    } else {
      throw Exception("File download failed!");
    }
  }

  /// 处理文件点击事件
  /// [file] : 点击的文件。这里还没有处理抽象，暂时全都是WebdavFile
  Future<void> onRemoteFileItemTapped(
    WebdavFile file,
    void Function(int count, int total)? onProgress,
  ) async {
    cancelToken?.cancel();
    final path = p.canonicalize(file.path);
    try {
      if (file.isDir) {
        await go(path);
      } else {
        final ext = p.extension(path);
        final downloadedFile = await downloadFile(
          path,
          ext: ext,
          onProgress: onProgress,
        );
        final result = await OpenFile.open(downloadedFile.path);
        if (result.type != ResultType.done) {
          logger.w('External file-open request did not complete.');
        } else {
          logger.d("成功调用外部 App");
        }
      }
    } on Object {
      logger.e('Remote file browser operation failed.');
      // 这里可以统一处理错误，比如更新 state 为 AsyncError
    }
  }

  /// 创建一个临时文件
  /// [fileExtension] : 文件后缀，比如 '.txt', '.jpg', '.pdf'
  Future<File> createTempFile({String fileExtension = '.tmp'}) async {
    try {
      final Directory tempDir = await getTemporaryDirectory();
      final String uniqueName = DateTime.now().millisecondsSinceEpoch
          .toString();
      final String fileName = 'temp_$uniqueName$fileExtension';
      final File tempFile = File('${tempDir.path}/$fileName');
      await tempFile.create(recursive: true);
      logger.d('Temporary download file created.');
      return tempFile;
    } on Object {
      logger.d('Temporary download file creation failed.');
      rethrow;
    }
  }

  void printCurrentStack() {
    logger.i('Remote browser history depth: ${_unstableStack.length}.');
  }

  String get _currentRootPath {
    final protocol = connectionModel.protocol;
    return _normalisePath(
      protocol is WebDavProtocolModel ? protocol.path ?? '/' : '/',
    );
  }

  String _normalisePath(String path) {
    final normalised = p.canonicalize(path.isEmpty ? '/' : path);
    return normalised == '.' ? '/' : normalised;
  }
}

class FileBrowserState {
  final String path;
  final String rootPath;
  final List<WebdavFile> files;

  const FileBrowserState({
    required this.path,
    required this.rootPath,
    required this.files,
  });

  // 根目录的初始状态
  factory FileBrowserState.root() =>
      const FileBrowserState(path: '/', rootPath: '/', files: []);

  // 辅助判断
  bool get isRoot => path == rootPath;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FileBrowserState &&
          runtimeType == other.runtimeType &&
          path == other.path &&
          rootPath == other.rootPath &&
          files == other.files; // 注意：List 比较通常需要 listEquals，这里简化处理

  @override
  int get hashCode => path.hashCode ^ rootPath.hashCode ^ files.hashCode;
}
