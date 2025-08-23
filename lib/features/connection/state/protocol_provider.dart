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

@riverpod
Future<bool> protocolConnectChecker(Ref ref, ProtocolModel protocol) async {
  // final dio = Dio();
  // dio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: (){
  //   final client = HttpClient();
  //   client.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  //   return client;
  // });
  // or
  // (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
  //   final client = HttpClient();
  //   client.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  //   return client;
  // };

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
