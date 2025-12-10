import 'dart:io';

import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

import '../model/connection_model.dart';

part '../../../generated/features/connection/state/files_provider.g.dart';

@riverpod
class RemoteFileBrowser extends _$RemoteFileBrowser {
  String _currentPath = '/';

  bool get canGoBack => _currentPath != '/' && _currentPath != '\\';

  CancelToken? cancelToken;

  final List<FileBrowserState> _unstableStack = List.empty(growable: true);

  WebdavClient get _client {
    final protocol = connectionModel.protocol;
    if (protocol.username?.isNotEmpty == true && protocol.password?.isNotEmpty == true) {
      return WebdavClient.basicAuth(
        url: '${protocol.address}:${protocol.port}',
        user: protocol.username!,
        pwd: protocol.password!,
      );
    }
    return WebdavClient.noAuth(url: '${protocol.address}:${protocol.port}');
  }

  @override
  FutureOr<FileBrowserState> build({required ConnectionModel connectionModel}) async {
    _currentPath = connectionModel.protocol.path ?? '/';
    return _fetchState(_currentPath);
  }

  /// 获取文件列表
  Future<FileBrowserState> _fetchState(String path) async {
    // 规范化输入路径
    path = p.canonicalize(path);
    final files = await _client.readDir(path);
    final fileBrowserState = FileBrowserState(path: path, files: files);

    // 只保留当前路径和父路径之上的
    _unstableStack.removeWhere((e) => path == e.path || p.isWithin(path, e.path));
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
      logger.d("已跳转到: ${newState.path}");
      return newState;
    });
  }

  /// 返回上一级目录
  Future<void> goBack() async {
    final currentState = state.value;
    if (currentState == null || currentState.isRoot) return;

    final parentPath = p.dirname(currentState.path);
    // 优先从历史里取数据，而不是重新请求
    final stackState = _unstableStack.where((e) => e.path == parentPath).singleOrNull;
    if (stackState != null) {
      state = AsyncValue.data(stackState);
      // 从历史栈移除当前这个没用的
      _unstableStack.removeLast();
    } else {
      logger.w("返回了，但是没在历史栈里找到: $parentPath");
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
    await _client.readFile(path, tempFile.path, onProgress: onProgress, cancelToken: cancelToken);
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
        final downloadedFile = await downloadFile(path, ext: ext, onProgress: onProgress);
        final result = await OpenFilex.open(downloadedFile.path);
        if (result.type != ResultType.done) {
          logger.w("打开失败: ${result.message}");
        } else {
          logger.d("成功调用外部 App");
        }
      }
    } catch (e, stack) {
      logger.e("操作失败", error: e, stackTrace: stack);
      // 这里可以统一处理错误，比如更新 state 为 AsyncError
    }
  }

  /// 创建一个临时文件
  /// [fileExtension] : 文件后缀，比如 '.txt', '.jpg', '.pdf'
  Future<File> createTempFile({String fileExtension = '.tmp'}) async {
    try {
      final Directory tempDir = await getTemporaryDirectory();
      final String uniqueName = DateTime.now().millisecondsSinceEpoch.toString();
      final String fileName = 'temp_$uniqueName$fileExtension';
      final File tempFile = File('${tempDir.path}/$fileName');
      await tempFile.create(recursive: true);
      logger.d('临时文件已创建: ${tempFile.path}');
      return tempFile;
    } catch (e) {
      logger.d('创建临时文件失败: $e');
      rethrow;
    }
  }

  void printCurrentStack() {
    final logList = _unstableStack.asMap().entries.map((e) => "Index[${e.key}] -> ${e.value.path}").toList();

    logger.i(logList);
  }
}

class FileBrowserState {
  final String path;
  final List<WebdavFile> files;

  const FileBrowserState({required this.path, required this.files});

  // 根目录的初始状态
  factory FileBrowserState.root() => const FileBrowserState(path: '/', files: []);

  // 辅助判断
  bool get isRoot => path == '/' || path == '\\';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FileBrowserState &&
          runtimeType == other.runtimeType &&
          path == other.path &&
          files == other.files; // 注意：List 比较通常需要 listEquals，这里简化处理

  @override
  int get hashCode => path.hashCode ^ files.hashCode;
}
