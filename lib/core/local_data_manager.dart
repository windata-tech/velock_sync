import 'package:shared_preferences/shared_preferences.dart';
import 'package:velock_sync/core/app_repository.dart';

import 'logger.dart';


/// 用于管理本地键值对数据的单例工具类。
///
/// 封装了 SharedPreferencesWithCache 和 SharedPreferencesAsync，
/// 提供缓存和异步两种访问模式，并内置了基础的错误处理和日志记录。
class LocalDataManager {
  static final LocalDataManager _instance = LocalDataManager._internal();
  static LocalDataManager get instance => _instance;

  LocalDataManager._internal();

  late SharedPreferencesWithCache _cachedStore;
  late SharedPreferencesAsync _asyncStore;

  // --- 缓存白名单 ---
  // 定义哪些键应该被 SharedPreferencesWithCache 缓存。
  // 只有这些键将通过 _cachedStore 处理，并能够进行同步读取。
  // 不在此列表中的键，如果尝试通过 get/set 方法访问，会抛出 ArgumentError。
  final Set<String> _cacheWhitelist = {
    AppKeys.themeMode,
    AppKeys.notificationEnabled,
    AppKeys.languageCode,
    AppKeys.syncTask,
    // 确保所有在 AppKeys 中定义的、你需要同步访问的键都添加到这里
  };

  // --- 初始化方法 ---

  /// 初始化数据管理器。
  ///
  /// 此方法必须在应用启动时（例如在 `main()` 方法中）调用一次。
  /// 它会异步地初始化内部的 SharedPreferencesWithCache 和 SharedPreferencesAsync 实例。
  Future<void> init() async {
    _cachedStore = await SharedPreferencesWithCache.create(
      cacheOptions: SharedPreferencesWithCacheOptions(
        allowList: _cacheWhitelist, // 只有白名单中的键才会被缓存
      ),
    );

    // 2. 创建 SharedPreferencesAsync 实例
    // 它是纯异步的，不使用本地内存缓存，每次操作都直接与平台存储交互。
    // SharedPreferencesAsync 没有 getInstance() 方法，直接构造即可。
    _asyncStore = SharedPreferencesAsync();

    // logd('LocalDataManager initialized successfully.');
  }

  // --- 缓存数据访问方法 (通过 SharedPreferencesWithCache) ---
  // 这些方法适用于你 `_cacheWhitelist` 中定义的键，并提供同步读取，异步写入（无成功返回）。
  // 如果尝试访问不在白名单中的键，将抛出 ArgumentError。

  /// 从缓存中同步获取布尔值。
  /// 仅适用于在 `_cacheWhitelist` 中定义的键。
  bool? getBool(String key, {bool? defaultValue}) {
    _checkKeyInCacheWhitelist(key, isCachedAccess: true);
    return _cachedStore.getBool(key) ?? defaultValue;
  }

  /// 设置布尔值，更新内存缓存并异步持久化到磁盘。
  /// 仅适用于在 `_cacheWhitelist` 中定义的键。
  /// 此方法返回 `Future<void>`，成功完成表示异步写入任务已提交，不保证磁盘即时持久化成功。
  /// 任何持久化失败将通过日志记录和重新抛出异常进行通知。
  Future<void> setBool(String key, bool value) async {
    _checkKeyInCacheWhitelist(key, isCachedAccess: true);
    try {
      await _cachedStore.setBool(key, value);
      _logPersistenceResult(key, true, 'setBool (cached)');
    } catch (e) {
      _logPersistenceResult(key, false, 'setBool (cached)', error: e);
      rethrow; // 重新抛出异常，让调用者可以捕获处理
    }
  }

  /// 从缓存中同步获取字符串值。
  /// 仅适用于在 `_cacheWhitelist` 中定义的键。
  String? getString(String key, {String? defaultValue}) {
    _checkKeyInCacheWhitelist(key, isCachedAccess: true);
    return _cachedStore.getString(key) ?? defaultValue;
  }

  /// 设置字符串值，更新内存缓存并异步持久化到磁盘。
  /// 仅适用于在 `_cacheWhitelist` 中定义的键。返回 `Future<void>`。
  Future<void> setString(String key, String value) async {
    _checkKeyInCacheWhitelist(key, isCachedAccess: true);
    try {
      await _cachedStore.setString(key, value);
      _logPersistenceResult(key, true, 'setString (cached)');
    } catch (e) {
      _logPersistenceResult(key, false, 'setString (cached)', error: e);
      rethrow;
    }
  }

  /// 从缓存中同步获取整数值。
  /// 仅适用于在 `_cacheWhitelist` 中定义的键。
  int? getInt(String key, {int? defaultValue}) {
    _checkKeyInCacheWhitelist(key, isCachedAccess: true);
    return _cachedStore.getInt(key) ?? defaultValue;
  }

  /// 设置整数值，更新内存缓存并异步持久化到磁盘。
  /// 仅适用于在 `_cacheWhitelist` 中定义的键。返回 `Future<void>`。
  Future<void> setInt(String key, int value) async {
    _checkKeyInCacheWhitelist(key, isCachedAccess: true);
    try {
      await _cachedStore.setInt(key, value);
      _logPersistenceResult(key, true, 'setInt (cached)');
    } catch (e) {
      _logPersistenceResult(key, false, 'setInt (cached)', error: e);
      rethrow;
    }
  }

  /// 从缓存中同步获取双精度浮点数值。
  /// 仅适用于在 `_cacheWhitelist` 中定义的键。
  double? getDouble(String key, {double? defaultValue}) {
    _checkKeyInCacheWhitelist(key, isCachedAccess: true);
    return _cachedStore.getDouble(key) ?? defaultValue;
  }

  /// 设置双精度浮点数值，更新内存缓存并异步持久化到磁盘。
  /// 仅适用于在 `_cacheWhitelist` 中定义的键。返回 `Future<void>`。
  Future<void> setDouble(String key, double value) async {
    _checkKeyInCacheWhitelist(key, isCachedAccess: true);
    try {
      await _cachedStore.setDouble(key, value);
      _logPersistenceResult(key, true, 'setDouble (cached)');
    } catch (e) {
      _logPersistenceResult(key, false, 'setDouble (cached)', error: e);
      rethrow;
    }
  }

  /// 从缓存中同步获取字符串列表。
  /// 仅适用于在 `_cacheWhitelist` 中定义的键。
  List<String>? getStringList(String key, {List<String>? defaultValue}) {
    _checkKeyInCacheWhitelist(key, isCachedAccess: true);
    return _cachedStore.getStringList(key) ?? defaultValue;
  }

  /// 设置字符串列表，更新内存缓存并异步持久化到磁盘。
  /// 仅适用于在 `_cacheWhitelist` 中定义的键。返回 `Future<void>`。
  Future<void> setStringList(String key, List<String> value) async {
    _checkKeyInCacheWhitelist(key, isCachedAccess: true);
    try {
      await _cachedStore.setStringList(key, value);
      _logPersistenceResult(key, true, 'setStringList (cached)');
    } catch (e) {
      _logPersistenceResult(key, false, 'setStringList (cached)', error: e);
      rethrow;
    }
  }

  /// 从缓存中移除键值对，并异步从持久化存储中移除。
  /// 仅适用于在 `_cacheWhitelist` 中定义的键。返回 `Future<void>`。
  Future<void> removeCached(String key) async {
    _checkKeyInCacheWhitelist(key, isCachedAccess: true);
    try {
      await _cachedStore.remove(key);
      _logPersistenceResult(key, true, 'removeCached');
    } catch (e) {
      _logPersistenceResult(key, false, 'removeCached');
      rethrow;
    }
  }

  // --- 异步数据访问方法 (通过 SharedPreferencesAsync) ---
  // 这些方法适用于所有键，特别是那些不在 `_cacheWhitelist` 中的键。
  // 它们都是异步的，直接与平台存储交互，不使用本地内存缓存。

  /// 异步获取布尔值。适用于所有键。返回 `Future<bool>`。
  Future<bool?> getBoolAsync(String key, {bool? defaultValue}) async {
    return await _asyncStore.getBool(key) ?? defaultValue;
  }

  /// 异步设置布尔值并持久化。适用于所有键。返回 `Future<void>`。
  Future<void> setBoolAsync(String key, bool value) async {
    try {
      await _asyncStore.setBool(key, value);
      _logPersistenceResult(key, true, 'setBoolAsync');
    } catch (e) {
      _logPersistenceResult(key, false, 'setBoolAsync', error: e);
      rethrow;
    }
  }

  /// 异步获取字符串值。适用于所有键。返回 `Future<String>`。
  Future<String?> getStringAsync(String key, {String? defaultValue}) async {
    return await _asyncStore.getString(key) ?? defaultValue;
  }

  /// 异步设置字符串值并持久化。适用于所有键。返回 `Future<void>`。
  Future<void> setStringAsync(String key, String value) async {
    try {
      await _asyncStore.setString(key, value);
      _logPersistenceResult(key, true, 'setStringAsync');
    } catch (e) {
      _logPersistenceResult(key, false, 'setStringAsync', error: e);
      rethrow;
    }
  }

  /// 异步获取整数值。适用于所有键。返回 `Future<int>`。
  Future<int?> getIntAsync(String key, {int? defaultValue}) async {
    return await _asyncStore.getInt(key) ?? defaultValue;
  }

  /// 异步设置整数值并持久化。适用于所有键。返回 `Future<void>`。
  Future<void> setIntAsync(String key, int value) async {
    try {
      await _asyncStore.setInt(key, value);
      _logPersistenceResult(key, true, 'setIntAsync');
    } catch (e) {
      _logPersistenceResult(key, false, 'setIntAsync', error: e);
      rethrow;
    }
  }

  /// 异步获取双精度浮点数值。适用于所有键。返回 `Future<double>`。
  Future<double?> getDoubleAsync(String key, {double? defaultValue}) async {
    return await _asyncStore.getDouble(key) ?? defaultValue;
  }

  /// 异步设置双精度浮点数值并持久化。适用于所有键。返回 `Future<void>`。
  Future<void> setDoubleAsync(String key, double value) async {
    try {
      await _asyncStore.setDouble(key, value);
      _logPersistenceResult(key, true, 'setDoubleAsync');
    } catch (e) {
      _logPersistenceResult(key, false, 'setDoubleAsync', error: e);
      rethrow;
    }
  }

  /// 异步获取字符串列表。适用于所有键。返回 `Future<List<String>>`。
  Future<List<String>?> getStringListAsync(String key, {List<String>? defaultValue}) async {
    return await _asyncStore.getStringList(key) ?? defaultValue;
  }

  /// 异步设置字符串列表并持久化。适用于所有键。返回 `Future<void>`。
  Future<void> setStringListAsync(String key, List<String> value) async {
    try {
      await _asyncStore.setStringList(key, value);
      _logPersistenceResult(key, true, 'setStringListAsync');
    } catch (e) {
      _logPersistenceResult(key, false, 'setStringListAsync', error: e);
      rethrow;
    }
  }

  /// 异步移除键值对。适用于所有键。返回 `Future<void>`。
  Future<void> removeAsync(String key) async {
    try {
      await _asyncStore.remove(key);
      _logPersistenceResult(key, true, 'removeAsync');
    } catch (e) {
      _logPersistenceResult(key, false, 'removeAsync');
      rethrow;
    }
  }

  // --- 辅助方法 ---

  /// 私有辅助方法，用于日志记录持久化结果。
  /// 只在调试模式下打印日志，并可以记录具体的错误信息。
  void _logPersistenceResult(String key, bool success, String methodName, {dynamic error}) {
    if (!success) {
      logw('LocalDataManager WARNING: $methodName for key "$key" failed to persist to disk! Error: $error');
    } else {
      // logd('LocalDataManager: $methodName for key "$key" persisted successfully.');
    }
  }

  /// 私有辅助方法，用于检查键是否在缓存白名单中，并根据访问类型抛出错误。
  /// 确保用户使用正确的访问方法（同步/异步）来操作键。
  void _checkKeyInCacheWhitelist(String key, {required bool isCachedAccess}) {
    final bool isInWhitelist = _cacheWhitelist.contains(key);
    if (isCachedAccess && !isInWhitelist) {
      // 尝试通过缓存方法访问，但键不在缓存白名单中
      throw ArgumentError(
        'Key "$key" is not in the `_cacheWhitelist`. '
        'Please use `get*Async`/`set*Async` for this key, '
        'or add "$key" to `_cacheWhitelist` if you intend to cache it.',
      );
    }
    // else if (!isCachedAccess && isInWhitelist) {
    //   // 尝试通过异步方法访问，但键在缓存白名单中。
    //   // 理论上这里也可以抛出错误，强制使用缓存方法，但通常异步方法可以访问所有键，所以不抛出。
    //   // 如果需要更严格的控制，可以在此添加 throw ArgumentError。
    // }
  }
}
