import 'package:fluttertoast/fluttertoast.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

part '../../../generated/features/connection/state/protocol_provider.g.dart';

@riverpod
List<ProtocolModel> supportedProtocols(Ref ref) {
  return [ProtocolModel.webDav(protocolType: WebDavProtocolType.http, address: '', port: '')];
}

// @riverpod
// class Protocols extends _$Protocols {
//   @override
//   FutureOr<List<ProtocolModel>> build() async {
//     final appSetting = ref.watch(appSettingProvider);
//     return appSetting.setLanguageCode(value);
//   }
// }

// @riverpod
// class Protocol extends _$Protocol {
//   @override
//   FutureOr<ProtocolModel?> build() async {
//     return state.value;
//   }
//
//   Future<void> setProtocol(ProtocolModel protocol) async {
//     state = AsyncValue.data(protocol);
//   }
//
//   Future<void> clearProtocol() async {
//     state = const AsyncValue.data(null);
//   }
//
//   ProtocolModel? get protocol => state.value;
//
//   bool get isProtocolSet => state.value != null;
// }

@riverpod
Future<bool> protocolConnectChecker(Ref ref, ProtocolModel protocol) async {
  switch (protocol) {
    case WebDavProtocolModel():
      WebdavClient client;
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
      try {
        await client.ping();
        return true;
      } catch (e, s) {
        if (e is WebdavException) {
          Fluttertoast.showToast(msg: 'WebDav发生错误: ${e.message}');
        } else {
          Fluttertoast.showToast(msg: 'WebDav连接发生错误: $e');
        }
        loge('----------- 发生错误 -----------');
        loge('错误类型: ${e.runtimeType}');
        loge('错误信息: $e');
        loge('堆栈跟踪: ', stackTrace: s);
        loge('------------------------------');
        return false;
      }
  }
  return true;
}
