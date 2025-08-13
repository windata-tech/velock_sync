import 'dart:io';

/// 检查字符串是否为有效的URL。
///
/// 这个版本对主机(host)部分进行了严格校验，必须满足以下条件之一：
/// 1. 是一个有效的IP地址 (v4或v6)。
/// 2. 是 'localhost'。
/// 3. 是一个包含至少一个 '.' 的域名。
///
/// @param input 要检查的字符串。
/// @param protocols 支持的协议列表。
/// @return 如果是有效且符合严格主机规则的URL，则返回 true。
bool isUrl(String input, {List<String> protocols = const ['http', 'https(']}) {
  if (input.isEmpty) {
    return false;
  }
  final Uri? uri = Uri.tryParse(input);
  if (uri == null || !uri.hasScheme || !protocols.contains(uri.scheme)) {
    return false;
  }

  final String host = uri.host;
  if (host.isEmpty) {
    return false;
  }

  if (InternetAddress.tryParse(host) != null) {
    return true;
  }

  if (host.toLowerCase() == 'localhost') {
    return true;
  }

  if (host.contains('.')) {
    return true;
  }
  return false;
}
