import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

import '../model/connection_model.dart';


part '../../../generated/features/connection/state/files_provider.g.dart';

@riverpod
class RemoteFiles extends _$RemoteFiles {
  WebdavClient? client;

  void _ensureClient({required ProtocolModel protocol}) {
    if (client != null) {
      return;
    }
    final protocol = connectionModel.protocol;
    if (protocol.username != null &&
        protocol.username!.isNotEmpty &&
        protocol.password != null &&
        protocol.password!.isNotEmpty) {
      client = WebdavClient.basicAuth(
        url: '${protocol.address}:${protocol.port}',
        user: protocol.username!,
        pwd: protocol.password!,
      );
    } else {
      client = WebdavClient.noAuth(url: '${protocol.address}:${protocol.port}');
    }
  }

  @override
  FutureOr<List<WebdavFile>> build({
    required ConnectionModel connectionModel,
  }) async {
    _ensureClient(protocol: connectionModel.protocol);
    final theClient = client!;
    final ret = await theClient.readDir('');
    return ret;
  }

  Future<void> go(String path) async {
    state = AsyncValue.loading();
    final ret = await client?.readDir(path);
    if (ret != null) {
      state = AsyncValue.data(ret);
    } else {
      state = AsyncValue.error("Error", StackTrace.current);
    }
  }

  Future<File> downloadFile(String path, {required String ext}) async {
    File tempFile = await createTempFile(fileExtension: ext);
    await client?.readFile(path, tempFile.path);
    if (tempFile.existsSync()) {
      return tempFile;
    } else {
      throw Exception("File download failed!");
    }
  }

  /// 创建一个临时文件
  /// [fileExtension] : 文件后缀，比如 '.txt', '.jpg', '.pdf'
  Future<File> createTempFile({String fileExtension = '.tmp'}) async {
    try {
      // 1. 获取临时目录 (在 Android 上是 cache 目录，iOS 上是 tmp 目录)
      // 系统可能会在磁盘空间不足时自动清理这个目录
      final Directory tempDir = await getTemporaryDirectory();

      // 2. 生成一个唯一的文件名
      // 这里使用 "毫秒时间戳" 简单防冲突，要求更高可以用 UUID
      final String uniqueName = DateTime.now().millisecondsSinceEpoch
          .toString();
      final String fileName = 'temp_$uniqueName$fileExtension';

      // 3. 拼接完整路径
      // 专家提示：永远不要用字符串拼接路径 (dir + "/" + name)，要用 FileSystemEntity (或者 path 库)
      final File tempFile = File('${tempDir.path}/$fileName');

      // 4. 创建文件
      // create(recursive: true) 意味着如果中间目录不存在，会自动创建
      await tempFile.create(recursive: true);

      print('✅ 临时文件已创建: ${tempFile.path}');
      return tempFile;
    } catch (e) {
      print('❌ 创建临时文件失败: $e');
      rethrow;
    }
  }
}
