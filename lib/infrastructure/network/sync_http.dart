import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:velock_sync/core/logger.dart';

/// Every HTTP client the app talks to a remote with.
///
/// Two things a bare `Dio()` gets wrong:
/// - no timeouts, so a blocked or black-holed host (an unreachable cloud, a
///   dropped network) leaves the caller waiting for ever;
/// - Dart's `HttpClient` ignores the system proxy, so a host that is only
///   reachable through it (Google behind the user's proxy) hangs while the
///   system browser, which honours the proxy, works fine.
Dio newSyncDio({
  Duration connectTimeout = const Duration(seconds: 30),
  Duration receiveTimeout = const Duration(minutes: 5),
  Duration sendTimeout = const Duration(minutes: 5),
}) => Dio(
  BaseOptions(
    connectTimeout: connectTimeout,
    receiveTimeout: receiveTimeout,
    sendTimeout: sendTimeout,
  ),
)..httpClientAdapter = IOHttpClientAdapter(createHttpClient: _newHttpClient);

HttpClient _newHttpClient() =>
    HttpClient()..findProxy = SystemProxy.instance.findProxy;

/// The platform's manual HTTP(S) proxy, read through a native channel and
/// applied the way native networking does: loopback and the platform's
/// exception list go direct, everything else through the proxy.
///
/// Only a manually configured proxy is honoured. An auto-config (PAC) proxy
/// is not evaluated and connections go direct; a VPN-style proxy needs
/// nothing here because it already carries every socket.
class SystemProxy {
  SystemProxy._();

  static final instance = SystemProxy._();

  static const _channel = MethodChannel(
    'tech.windata.velock.sync/system_proxy',
  );

  SystemProxySettings _settings = SystemProxySettings.none;

  SystemProxySettings get settings => _settings;

  /// Re-reads the platform settings. Call at startup and when the app comes
  /// back to the foreground; clients created afterwards use the result.
  /// Any failure (no channel on this platform, a background isolate) leaves
  /// connections direct, which is what they were before.
  Future<void> refresh() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('current');
      _settings = SystemProxySettings.fromPlatform(raw);
    } on MissingPluginException {
      _settings = SystemProxySettings.none;
    } on Object catch (error) {
      logw('Reading the system proxy failed: $error');
      _settings = SystemProxySettings.none;
    }
  }

  String findProxy(Uri uri) => _settings.findProxy(uri);
}

@immutable
class SystemProxySettings {
  const SystemProxySettings({
    this.http,
    this.https,
    this.exceptions = const [],
    this.excludeSimpleHostnames = false,
  });

  static const none = SystemProxySettings();

  /// `host:port` for plain-HTTP and HTTPS requests, or null to go direct.
  final String? http;
  final String? https;
  final List<String> exceptions;
  final bool excludeSimpleHostnames;

  /// Parses the channel's map. Anything malformed means "no proxy": a
  /// half-read setting must never send traffic somewhere unexpected.
  factory SystemProxySettings.fromPlatform(Map<String, Object?>? raw) {
    if (raw == null) return none;
    String? endpoint(String prefix) {
      if (raw['${prefix}Enable'] != true) return null;
      final host = raw['${prefix}Host'];
      final port = raw['${prefix}Port'];
      if (host is! String || !_validHost(host)) return null;
      if (port is! int || port <= 0 || port > 65535) return null;
      return '${host.contains(':') ? '[$host]' : host}:$port';
    }

    final exceptions = raw['exceptions'];
    return SystemProxySettings(
      http: endpoint('http'),
      https: endpoint('https'),
      exceptions: exceptions is List
          ? [
              for (final entry in exceptions)
                if (entry is String && entry.trim().isNotEmpty)
                  entry.trim().toLowerCase(),
            ]
          : const [],
      excludeSimpleHostnames: raw['excludeSimpleHostnames'] == true,
    );
  }

  static bool _validHost(String host) =>
      host.isNotEmpty && RegExp(r'^[A-Za-z0-9.\-:]+$').hasMatch(host);

  String findProxy(Uri uri) {
    final proxy = switch (uri.scheme) {
      'https' => https,
      'http' => http,
      _ => null,
    };
    if (proxy == null || bypasses(uri.host)) return 'DIRECT';
    return 'PROXY $proxy';
  }

  /// Hosts that never go through the proxy.
  bool bypasses(String rawHost) {
    final host = rawHost.toLowerCase();
    if (host == 'localhost' || host.endsWith('.localhost')) return true;
    final address = InternetAddress.tryParse(host);
    if (address != null && (address.isLoopback || address.isLinkLocal)) {
      return true;
    }
    if (excludeSimpleHostnames && address == null && !host.contains('.')) {
      return true;
    }
    for (final rule in exceptions) {
      if (_matches(rule, host, address)) return true;
    }
    return false;
  }

  static bool _matches(String rule, String host, InternetAddress? address) {
    if (rule.contains('/')) {
      return address != null && _inCidr(rule, address);
    }
    if (rule.startsWith('*.')) {
      final suffix = rule.substring(1);
      return host.endsWith(suffix) || host == rule.substring(2);
    }
    if (rule.startsWith('.')) {
      return host.endsWith(rule) || host == rule.substring(1);
    }
    if (rule.contains('*')) {
      final pattern = RegExp(
        '^${rule.split('*').map(RegExp.escape).join('.*')}\$',
      );
      return pattern.hasMatch(host);
    }
    return host == rule;
  }

  static bool _inCidr(String rule, InternetAddress address) {
    final slash = rule.indexOf('/');
    final network = InternetAddress.tryParse(rule.substring(0, slash));
    final bits = int.tryParse(rule.substring(slash + 1));
    if (network == null || bits == null || network.type != address.type) {
      return false;
    }
    final a = network.rawAddress;
    final b = address.rawAddress;
    if (bits < 0 || bits > a.length * 8) return false;
    for (var i = 0; i < bits; i++) {
      final mask = 0x80 >> (i % 8);
      if ((a[i ~/ 8] & mask) != (b[i ~/ 8] & mask)) return false;
    }
    return true;
  }
}
