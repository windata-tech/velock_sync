import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part '../../generated/core/state/download.g.dart';

@Riverpod(keepAlive: true) // keepAlive 保证离开页面后下载不中断
class DownloadManager extends _$DownloadManager {
  // 内部变量：用于控制网络请求的取消令牌，不属于UI状态的一部分
  final Map<String, CancelToken> _cancelTokens = {};
  final Dio _dio = Dio();

  @override
  FutureOr<List<DownloadTask>> build() async {
    // 初始时返回空列表，或者你可以从本地数据库(Isar/Hive)加载历史记录
    return [];
  }

  // --- 核心功能：开始下载 ---
  Future<void> startDownload(String url) async {
    final id = url.hashCode.toString(); // 简单生成ID，实际可用 uuid

    // 1. 获取保存路径 (这里简化为临时目录)
    final dir = await getApplicationDocumentsDirectory();
    final savePath = '${dir.path}/${id}_file.dat';

    // 2. 创建新任务
    final task = DownloadTask(id: id, url: url, savePath: savePath, status: DownloadStatus.downloading);

    // 3. 更新状态：添加到列表
    _addOrUpdateTask(task);

    // 4. 发起请求
    final cancelToken = CancelToken();
    _cancelTokens[id] = cancelToken;

    try {
      await _dio.download(
        url,
        savePath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            // 计算进度
            final progress = received / total;
            // 优化：不要频繁更新状态，可以加个节流阀，这里为了演示直接更新
            _updateProgress(id, progress);
          }
        },
      );

      // 下载完成
      _updateStatus(id, DownloadStatus.completed);
      _cancelTokens.remove(id);
    } catch (e) {
      if (e is DioException) {
        if (CancelToken.isCancel(e)) {
          _updateStatus(id, DownloadStatus.canceled, error: e.toString());
          return;
        }
      }
      _updateStatus(id, DownloadStatus.failed, error: e.toString());
      _cancelTokens.remove(id);
    }
  }

  // --- 核心功能：暂停任务 ---
  void pauseDownload(String id) {
    if (_cancelTokens.containsKey(id)) {
      _cancelTokens[id]?.cancel('User paused');
      _cancelTokens.remove(id);
      _updateStatus(id, DownloadStatus.paused);
    }
  }

  // --- 核心功能：恢复任务 ---
  void resumeDownload(String id) {
    // 恢复本质上是带着已有的文件长度去重新请求 Range，
    // 这里为了简化逻辑，我们假设暂且重新下载或者需要实现断点续传逻辑
    // 在这里找到对应的 task，重新调用 startDownload 即可
    // (真正的断点续传需要在 dio header 里加 "range": "bytes=$start-")

    final tasks = state.value ?? [];
    final task = tasks.firstWhere((t) => t.id == id);
    startDownload(task.url);
  }

  // --- 内部辅助：添加或更新任务 ---
  void _addOrUpdateTask(DownloadTask task) {
    final previousList = state.value ?? [];
    // 如果已存在则替换，不存在则追加
    final index = previousList.indexWhere((t) => t.id == task.id);

    if (index != -1) {
      final newList = List<DownloadTask>.from(previousList);
      newList[index] = task;
      state = AsyncData(newList);
    } else {
      state = AsyncData([...previousList, task]);
    }
  }

  // --- 内部辅助：更新进度 ---
  void _updateProgress(String id, double progress) {
    final previousList = state.value ?? [];
    final newList = previousList.map((task) {
      if (task.id == id) {
        return task.copyWith(progress: progress);
      }
      return task;
    }).toList();
    state = AsyncData(newList);
  }

  // --- 内部辅助：更新状态 ---
  void _updateStatus(String id, DownloadStatus status, {String? error}) {
    final previousList = state.value ?? [];
    final newList = previousList.map((task) {
      if (task.id == id) {
        return task.copyWith(status: status, errorMessage: error);
      }
      return task;
    }).toList();
    state = AsyncData(newList);
  }
}

// 定义下载状态枚举
enum DownloadStatus {
  initial, // 初始状态
  downloading, // 下载中
  paused, // 暂停
  completed, // 完成
  failed, // 失败
  canceled, // 取消
}

// 定义下载任务模型
// (这里为了演示清晰使用了标准Dart类，实际项目中建议用 Freezed 生成)
class DownloadTask {
  final String id; // 唯一ID (比如 url 的哈希值)
  final String url; // 下载链接
  final String savePath; // 本地保存路径
  final double progress; // 进度 0.0 - 1.0
  final DownloadStatus status;
  final String? errorMessage;

  const DownloadTask({
    required this.id,
    required this.url,
    required this.savePath,
    this.progress = 0.0,
    this.status = DownloadStatus.initial,
    this.errorMessage,
  });

  // 复制并修改 (Immutability is key in Riverpod)
  DownloadTask copyWith({double? progress, DownloadStatus? status, String? errorMessage}) {
    return DownloadTask(
      id: id,
      url: url,
      savePath: savePath,
      progress: progress ?? this.progress,
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}
