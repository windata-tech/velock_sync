import 'package:dio/dio.dart';
import 'package:velock_sync/infrastructure/secure_storage/credential_store.dart';
import 'package:velock_sync/providers/oauth/oauth_access_token_provider.dart';
import 'package:velock_sync/providers/oauth/oauth_remote_target_factory.dart';
import 'package:velock_sync/providers/oauth/oauth_token_client.dart';
import 'package:velock_sync/providers/provider_rate_limit_retry.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// Provider-neutral folder metadata used only while selecting a remote root.
class OAuthRemoteFolder {
  const OAuthRemoteFolder({required this.id, required this.name});

  final String id;
  final String name;
}

class OAuthRemoteFolderPage {
  const OAuthRemoteFolderPage({required this.items, this.nextCursor});

  final List<OAuthRemoteFolder> items;
  final String? nextCursor;
}

/// Lists only folders accessible to the authenticated OAuth application.
/// Tokens remain in [CredentialStore]; this API returns no provider payloads
/// beyond folder IDs and display names required for user selection.
class OAuthRemoteFolderPicker {
  OAuthRemoteFolderPicker({
    required CredentialStore credentialStore,
    OAuthTokenClient? tokenClient,
    Dio? dio,
    ProviderRateLimitRetry? rateLimitRetry,
  }) : _dio = dio ?? Dio(),
       _tokenClient = tokenClient ?? OAuthTokenClient(dio: dio),
       _credentialStore = credentialStore,
       _rateLimitRetry = rateLimitRetry ?? ProviderRateLimitRetry();

  static final _googleFiles = Uri.https(
    'www.googleapis.com',
    '/drive/v3/files',
  );
  static final _graph = Uri.https('graph.microsoft.com', '/v1.0/me/drive');

  final Dio _dio;
  final OAuthTokenClient _tokenClient;
  final CredentialStore _credentialStore;
  final ProviderRateLimitRetry _rateLimitRetry;

  Future<OAuthRemoteFolderPage> listFolders({
    required OAuthRemoteTargetConfig target,
    String? parentId,
    String? cursor,
  }) async {
    final tokens = _tokens(target);
    return switch (target.providerType) {
      RemoteProviderType.googleDrive => _listGoogle(
        tokens: tokens,
        parentId: parentId ?? 'root',
        cursor: cursor,
      ),
      RemoteProviderType.oneDrive => _listOneDrive(
        tokens: tokens,
        parentId: parentId,
        cursor: cursor,
      ),
      _ => throw UnsupportedError(
        '${target.providerType.name} does not support public folder picking.',
      ),
    };
  }

  /// Loads every page for a folder selection view. Listing folders is
  /// idempotent, so each page may safely use the transient-error retry policy.
  Future<List<OAuthRemoteFolder>> listAllFolders({
    required OAuthRemoteTargetConfig target,
    String? parentId,
  }) async {
    final folders = <OAuthRemoteFolder>[];
    String? cursor;
    do {
      final page = await listFolders(
        target: target,
        parentId: parentId,
        cursor: cursor,
      );
      folders.addAll(page.items);
      cursor = page.nextCursor;
    } while (cursor != null);
    return folders;
  }

  Future<OAuthRemoteFolderPage> _listGoogle({
    required OAuthAccessTokenProvider tokens,
    required String parentId,
    required String? cursor,
  }) async {
    final response = await _authorizedRequest<Map<String, dynamic>>(
      tokens,
      (headers) => _dio.getUri(
        _googleFiles.replace(
          queryParameters: {
            'q':
                "'${_escapeGoogleQuery(parentId)}' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false",
            'pageSize': '100',
            'pageToken': ?cursor,
            'fields': 'nextPageToken,files(id,name)',
          },
        ),
        options: Options(
          headers: headers,
          validateStatus: (status) => status != null && status < 600,
        ),
      ),
    );
    final raw = response.data?['files'];
    final folders = <OAuthRemoteFolder>[];
    if (raw is List) {
      for (final value in raw) {
        if (value is Map && value['id'] is String && value['name'] is String) {
          folders.add(
            OAuthRemoteFolder(
              id: value['id'] as String,
              name: value['name'] as String,
            ),
          );
        }
      }
    }
    return OAuthRemoteFolderPage(
      items: folders,
      nextCursor: response.data?['nextPageToken'] as String?,
    );
  }

  Future<OAuthRemoteFolderPage> _listOneDrive({
    required OAuthAccessTokenProvider tokens,
    required String? parentId,
    required String? cursor,
  }) async {
    final uri = cursor == null
        ? parentId == null || parentId == 'root'
              ? _graph.replace(
                  path: '${_graph.path}/root/children',
                  queryParameters: {
                    r'$select': 'id,name,folder',
                    r'$top': '100',
                  },
                )
              : _graph.replace(
                  path: '${_graph.path}/items/$parentId/children',
                  queryParameters: {
                    r'$select': 'id,name,folder',
                    r'$top': '100',
                  },
                )
        : Uri.parse(cursor);
    final response = await _authorizedRequest<Map<String, dynamic>>(
      tokens,
      (headers) => _dio.getUri(
        uri,
        options: Options(
          headers: headers,
          validateStatus: (status) => status != null && status < 600,
        ),
      ),
    );
    final raw = response.data?['value'];
    final folders = <OAuthRemoteFolder>[];
    if (raw is List) {
      for (final value in raw) {
        if (value is Map &&
            value['folder'] is Map &&
            value['id'] is String &&
            value['name'] is String) {
          folders.add(
            OAuthRemoteFolder(
              id: value['id'] as String,
              name: value['name'] as String,
            ),
          );
        }
      }
    }
    return OAuthRemoteFolderPage(
      items: folders,
      nextCursor: response.data?['@odata.nextLink'] as String?,
    );
  }

  Future<Response<T>> _authorizedRequest<T>(
    OAuthAccessTokenProvider tokens,
    Future<Response<T>> Function(Map<String, String> headers) send,
  ) async {
    try {
      return await _rateLimitRetry.executeTransient(() async {
        var response = await send(await tokens.authorizationHeaders());
        if (response.statusCode == 401) {
          response = await send(
            await tokens.authorizationHeaders(forceRefresh: true),
          );
        }
        final status = response.statusCode;
        // Let the retry helper observe 429 and 5xx responses before mapping
        // all other provider errors to our safe, provider-neutral exception.
        if (status == 429 || (status != null && status >= 500)) {
          return response;
        }
        if (status == null || status < 200 || status >= 300) {
          throw ProviderRequestException.fromStatus(status ?? 500);
        }
        return response;
      });
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status != null) throw ProviderRequestException.fromStatus(status);
      rethrow;
    }
  }

  OAuthAccessTokenProvider _tokens(OAuthRemoteTargetConfig target) {
    if (target.clientId.isEmpty || target.credentialRef.isEmpty) {
      throw ArgumentError('OAuth remote target configuration is incomplete.');
    }
    final tokenEndpoint = switch (target.providerType) {
      RemoteProviderType.googleDrive => Uri.https(
        'oauth2.googleapis.com',
        '/token',
      ),
      RemoteProviderType.oneDrive => Uri.https(
        'login.microsoftonline.com',
        '/common/oauth2/v2.0/token',
      ),
      _ => throw UnsupportedError(
        'Provider has no public OAuth token endpoint.',
      ),
    };
    return OAuthAccessTokenProvider(
      credentialStore: _credentialStore,
      tokenClient: _tokenClient,
      credentialRef: target.credentialRef,
      clientId: target.clientId,
      tokenEndpoint: tokenEndpoint,
    );
  }

  static String _escapeGoogleQuery(String value) =>
      value.replaceAll("'", r"\'");
}
