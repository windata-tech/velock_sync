import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// User-facing, conservative description of the capabilities enabled by the
/// first-party provider adapters. It deliberately describes only guarantees
/// the app can make, rather than leaking provider API details or credentials.
class ProviderCapabilitySummary {
  const ProviderCapabilitySummary({
    required this.providerName,
    required this.features,
    required this.limitations,
  });

  final String providerName;
  final List<String> features;
  final List<String> limitations;
}

ProviderCapabilitySummary providerCapabilitySummary(ProtocolModel protocol) =>
    switch (protocol) {
      WebDavProtocolModel() => const ProviderCapabilitySummary(
        providerName: 'WebDAV',
        features: ['条件创建', '范围下载', '安全存储密码'],
        limitations: ['断点续传取决于服务器能力；当前适配器会安全重试不可变对象。'],
      ),
      OAuthProtocolModel(providerType: RemoteProviderType.googleDrive) =>
        const ProviderCapabilitySummary(
          providerName: 'Google Drive',
          features: ['PKCE 授权', '可恢复上传', '范围下载', '回收站'],
          limitations: ['仅可访问授权应用可见的文件和已选择的目录。'],
        ),
      OAuthProtocolModel(providerType: RemoteProviderType.oneDrive) =>
        const ProviderCapabilitySummary(
          providerName: 'OneDrive',
          features: ['PKCE 授权', '可恢复上传', '范围下载', '回收站'],
          limitations: ['目录访问受 Microsoft Graph 授权范围和账户策略限制。'],
        ),
      OAuthProtocolModel(:final providerType) => ProviderCapabilitySummary(
        providerName: providerType.name,
        features: const [],
        limitations: const ['此 Provider 需要官方 Token Broker 后才能启用。'],
      ),
    };
