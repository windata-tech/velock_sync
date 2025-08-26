import 'dart:async';
import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/app_repository.dart';
import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/protocol_provider.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';
import 'package:collection/collection.dart';
class ConnectionRepository {
  ConnectionRepository(this._localDataManager);

  final LocalDataManager _localDataManager;

  List<ConnectionModel>? get connections {
    final json = _localDataManager.getStringList(AppKeys.connections);
    if (json == null) return null;
    return json.map((e) => ConnectionModel.fromJson(jsonDecode(e))).toList();
  }

  Future<void> setConnections(List<ConnectionModel> value) {
    final json = value.map((e) => jsonEncode(e.toJson())).toList();
    return _localDataManager.setStringList(AppKeys.connections, json);
  }

  Future<ConnectionModel?> getConnectionById(String id) async {
    final conns = connections;
    if (conns == null) return null;
    return conns.firstWhereOrNull((conn) => conn.id == id);
  }

  // List<ProtocolModel>? get protocols {
  //   final json = _localDataManager.getStringList(AppKeys.protocols);
  // }

  // FutureOr<bool> connect(ConnectionModel connectionModel) async {
  //   final protocol = connectionModel.protocol;
  //   final checker = protocolConnectCheckerProvider(protocol).future;


    // final protocol = connectionModel.protocol;
    // switch (protocol) {
    //   case WebDavProtocolModel():
    //     WebdavClient client;
    //     if (protocol.username != null && protocol.username!.isNotEmpty && protocol.password != null && protocol.password!.isNotEmpty) {
    //       client = WebdavClient.basicAuth(url: protocol.address, user: protocol.username!, pwd: protocol.password!);
    //     } else {
    //       client = WebdavClient.noAuth(url: protocol.address);
    //     }
    //     try {
    //       await client.ping();
    //       return true;
    //     } catch (e) {
    //       return false;
    //     }
    // }
  // }
}
