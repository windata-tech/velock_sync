import 'package:material_ui/material_ui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/providers/baidu_netdisk/baidu_netdisk_object_store.dart';
import 'package:velock_sync/providers/remote_provider_availability.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';

/// Detailed, provider-specific setup documentation.
///
/// The form pages only link here. Keeping the long-form explanation separate
/// leaves the form focused on entering values while still making every setup
/// detail available when it is needed.
///
/// Every sentence is built per locale, so the documents are functions of the
/// current [BuildContext] rather than compile-time constants.
class ConnectionHelpPage extends ConsumerWidget {
  const ConnectionHelpPage({super.key, this.providerType});

  final RemoteProviderType? providerType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Every type can be set up — a cloud drive without a built-in key takes
    // the user's own app registration — so the overview documents them all.
    final documents = providerType == null
        ? [
            _documentFor(context, RemoteProviderType.webDav),
            for (final type in RemoteProviderAvailability.oauthProviderTypes)
              _documentFor(context, type),
          ]
        : [_documentFor(context, providerType!)];

    return AdaptiveScaffold(
      title: providerType == null
          ? syncText(context, '连接说明', 'Connection info')
          : syncText(
              context,
              '${documents.single.title} 配置说明',
              '${documents.single.title} setup',
            ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          AppSpacing.md,
          AppSpacing.page,
          AppSpacing.xl,
        ),
        children: [
          Text(
            providerType == null
                ? syncText(
                    context,
                    '这里说明每个远端服务需要提前准备什么、字段怎么填写、保存后会发生什么，以及遇到错误时从哪里开始排查。',
                    'What each remote service needs beforehand, how to fill in the fields, what happens after saving, and where to start when something fails.',
                  )
                : documents.single.intro,
            style: AppType.body.copyWith(color: context.appSecondaryLabel),
          ),
          const SizedBox(height: AppSpacing.lg),
          for (var index = 0; index < documents.length; index++)
            _ConnectionHelpDocument(
              document: documents[index],
              showTitle: providerType == null,
              isLast: index == documents.length - 1,
            ),
        ],
      ),
    );
  }

  static ConnectionHelpDocument _documentFor(
    BuildContext context,
    RemoteProviderType provider,
  ) => switch (provider) {
    RemoteProviderType.webDav => _webDavDocument(context),
    RemoteProviderType.googleDrive => _googleDriveDocument(context),
    RemoteProviderType.oneDrive => _oneDriveDocument(context),
    RemoteProviderType.baiduNetdisk => _baiduNetdiskDocument(context),
    RemoteProviderType.aliyunDrive => _aliyunDriveDocument(context),
  };
}

class _ConnectionHelpDocument extends StatelessWidget {
  const _ConnectionHelpDocument({
    required this.document,
    required this.showTitle,
    required this.isLast,
  });

  final ConnectionHelpDocument document;
  final bool showTitle;
  final bool isLast;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: isLast ? 0 : AppSpacing.lg),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showTitle) ...[
          Text(
            document.title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            document.intro,
            style: AppType.body.copyWith(color: context.appSecondaryLabel),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        for (final section in document.sections)
          _ConnectionHelpSection(section: section),
      ],
    ),
  );
}

class _ConnectionHelpSection extends StatelessWidget {
  const _ConnectionHelpSection({required this.section});

  final ConnectionHelpSection section;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.lg),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          section.title,
          style: AppType.caption.copyWith(color: context.appSecondaryLabel),
        ),
        const SizedBox(height: AppSpacing.xs),
        for (var index = 0; index < section.items.length; index++)
          _ConnectionHelpItem(item: section.items[index], index: index + 1),
      ],
    ),
  );
}

class _ConnectionHelpItem extends StatelessWidget {
  const _ConnectionHelpItem({required this.item, required this.index});

  final ConnectionHelpItem item;
  final int index;

  @override
  Widget build(BuildContext context) {
    final titleStyle = AppType.rowTitle.copyWith(fontWeight: FontWeight.w600);
    final numberStyle = titleStyle.copyWith(
      color: context.appPrimary,
      fontWeight: FontWeight.w700,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              SizedBox(width: 24, child: Text('$index.', style: numberStyle)),
              Expanded(child: Text(item.title, style: titleStyle)),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 24, top: AppSpacing.xxs),
            child: Text(
              item.body,
              style: AppType.body.copyWith(color: context.appSecondaryLabel),
            ),
          ),
          if (item.bullets.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: AppSpacing.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final bullet in item.bullets)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.xxs),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 14,
                            child: Text(
                              '•',
                              style: TextStyle(
                                color: context.appSecondaryLabel,
                                height: 1.45,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              bullet,
                              style: TextStyle(
                                color: context.appSecondaryLabel,
                                height: 1.45,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class ConnectionHelpDocument {
  const ConnectionHelpDocument({
    required this.title,
    required this.intro,
    required this.sections,
  });

  final String title;
  final String intro;
  final List<ConnectionHelpSection> sections;
}

class ConnectionHelpSection {
  const ConnectionHelpSection({required this.title, required this.items});

  final String title;
  final List<ConnectionHelpItem> items;
}

class ConnectionHelpItem {
  const ConnectionHelpItem({
    required this.title,
    required this.body,
    this.bullets = const [],
  });

  final String title;
  final String body;
  final List<String> bullets;
}

ConnectionHelpDocument _webDavDocument(
  BuildContext context,
) => ConnectionHelpDocument(
  title: 'WebDAV',
  intro: syncText(
    context,
    'WebDAV 适合连接 NAS、Nextcloud 或其他兼容服务。请先确认当前设备能访问服务器，再填写表单。',
    'WebDAV works with a NAS, Nextcloud or another compatible service. Make sure this device can reach the server first, then fill in the form.',
  ),
  sections: [
    ConnectionHelpSection(
      title: syncText(context, '开始前准备', 'Before you start'),
      items: [
        ConnectionHelpItem(
          title: syncText(
            context,
            '确认服务端已开启 WebDAV',
            'Check that WebDAV is switched on',
          ),
          body: syncText(
            context,
            '服务端需要允许当前账号进行目录读取、创建目录、上传、下载和删除操作。只开启网页管理后台，不代表 WebDAV 已经可用。',
            'The server must let this account list, create, upload, download and delete files. A web admin page being open does not mean WebDAV is available.',
          ),
          bullets: [
            syncText(
              context,
              '确认 WebDAV 服务的实际访问地址和监听端口。',
              'Find the real address and port the WebDAV service listens on.',
            ),
            syncText(
              context,
              '确认账号对目标目录有读写权限，而不是只有只读权限。',
              'Make sure the account can write to the target folder, not only read it.',
            ),
            syncText(
              context,
              '如果服务端按应用单独生成密码，请使用应用密码，不要填登录后台的其他凭据。',
              'If the server issues a separate password for apps, use that app password instead of your admin sign-in details.',
            ),
          ],
        ),
        ConnectionHelpItem(
          title: syncText(context, '先确认网络可达', 'Check the network first'),
          body: syncText(
            context,
            '在同一台设备上用浏览器或其他 WebDAV 客户端访问服务器，先排除 DNS、VPN、局域网隔离和防火墙问题。',
            'Open the server from this same device with a browser or another WebDAV client, to rule out DNS, VPN, network isolation and firewall problems.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '优先使用 HTTPS', 'Prefer HTTPS'),
          body: syncText(
            context,
            'HTTPS 会保护账号凭据和同步数据在传输过程中的机密性。只有在可信内网、且服务器确实无法提供 HTTPS 时，才考虑关闭 HTTPS。',
            'HTTPS keeps your account details and sync data private while they travel. Only turn HTTPS off on a trusted local network where the server really cannot offer it.',
          ),
        ),
      ],
    ),
    ConnectionHelpSection(
      title: syncText(context, '字段怎么填', 'How to fill in each field'),
      items: [
        ConnectionHelpItem(
          title: syncText(context, '启用 HTTPS', 'Enable HTTPS'),
          body: syncText(
            context,
            '开关必须和服务器地址的协议一致。开启时地址以 https:// 开头，通常端口为 443；关闭时地址以 http:// 开头，通常端口为 80。',
            'The switch must match the address. With it on, the address starts with https:// and the port is usually 443; with it off, the address starts with http:// and the port is usually 80.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '服务器地址', 'Server address'),
          body: syncText(
            context,
            '填写服务端的基础地址，例如 https://nas.example.com。地址必须包含协议和主机名；不要把用户名和密码写进 URL。',
            'Enter the base address of the server, for example https://nas.example.com. It must include the scheme and the host name; never put a username or password in the URL.',
          ),
          bullets: [
            syncText(
              context,
              '如果服务端给出的地址已经包含固定目录，可以按服务端文档原样填写。',
              'If the address you were given already contains a fixed folder, enter it exactly as the server documents say.',
            ),
            syncText(
              context,
              '如果固定目录单独填写在“子路径”，两个字段不要重复写同一段路径。',
              'If that folder belongs in “Subpath” instead, do not repeat the same path in both fields.',
            ),
          ],
        ),
        ConnectionHelpItem(
          title: syncText(context, '端口', 'Port'),
          body: syncText(
            context,
            '填写服务器实际监听的数字端口。443 和 80 只是常见默认值，NAS 或反向代理使用自定义端口时，以服务端配置为准。',
            'Enter the number the server actually listens on. 443 and 80 are only common defaults; when a NAS or reverse proxy uses a custom port, follow the server configuration.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '子路径', 'Subpath'),
          body: syncText(
            context,
            '填写 WebDAV 服务下用于保存同步对象的目录段，例如 /webdav 或 /remote/velock。留空表示从服务端基础目录开始。',
            'Enter the folder under the WebDAV service where synced items are kept, for example /webdav or /remote/velock. Leave it empty to start at the server base folder.',
          ),
          bullets: [
            syncText(
              context,
              '不要填完整 URL，也不要再次填写 https:// 和主机名。',
              'Do not enter a full URL, and do not repeat https:// or the host name.',
            ),
            syncText(
              context,
              '如果服务端文档要求路径以 / 开头，请按文档填写；不要凭感觉改成文件系统路径。',
              'If the server documentation requires a leading /, follow it; do not guess a filesystem path instead.',
            ),
          ],
        ),
        ConnectionHelpItem(
          title: syncText(context, '用户名和密码', 'Username and password'),
          body: syncText(
            context,
            '服务器要求认证时，两项一起填写。匿名 WebDAV 才可以同时留空；填写密码但不填用户名，或反过来，通常会导致认证失败。编辑已有连接时，密码留空表示保留原密码。',
            'Fill in both when the server requires sign-in. Only anonymous WebDAV can leave both empty; a password without a username, or the reverse, usually fails. When editing an existing connection, an empty password keeps the current one.',
          ),
        ),
      ],
    ),
    ConnectionHelpSection(
      title: syncText(context, '保存时会发生什么', 'What happens when you save'),
      items: [
        ConnectionHelpItem(
          title: syncText(context, '先做表单校验', 'The form is checked first'),
          body: syncText(
            context,
            '应用会检查地址格式、协议前缀和必填端口。校验提示出现时，先修正字段，不会开始网络连接。',
            'The app checks the address format, the scheme prefix and the required port. If a message appears, fix that field first; no network request is made yet.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '再测试实际连接',
            'Then the real connection is tested',
          ),
          body: syncText(
            context,
            '点击保存后，应用会使用填写的地址、端口、路径和凭据访问远端目录，确认连接可以用于同步。测试失败时不会把一个未验证的连接留在列表里。',
            'After you tap Save, the app uses the address, port, path and credentials you entered to reach the remote folder and confirm the connection can carry syncing. A connection that fails this test is not kept in the list.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '凭据单独保存',
            'Credentials are stored separately',
          ),
          body: syncText(
            context,
            '密码只写入系统安全存储，连接配置本身不会包含明文密码。保存成功后，连接会回到“连接”页面。',
            'The password goes only into system secure storage; the connection settings never hold a plain-text password. When saving succeeds, you return to the “Connections” page.',
          ),
        ),
      ],
    ),
    ConnectionHelpSection(
      title: syncText(
        context,
        '失败时按这个顺序排查',
        'If it fails, check in this order',
      ),
      items: [
        ConnectionHelpItem(
          title: syncText(
            context,
            '先看地址和协议',
            'Start with the address and scheme',
          ),
          body: syncText(
            context,
            '确认 https/http 与开关一致，主机名没有拼写错误，地址没有多余空格，也没有把端口重复写进路径。',
            'Check that https/http matches the switch, that the host name is spelled correctly, that the address has no stray spaces, and that the port is not repeated inside the path.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '再看端口和路径', 'Then the port and path'),
          body: syncText(
            context,
            '用服务端提供的 WebDAV 地址验证端口；如果返回 404 或找不到目录，检查子路径是否是 WebDAV 根路径，而不是网页后台路径。',
            'Verify the port with the WebDAV address the server gave you. If you get a 404 or a missing folder, check that the subpath is the WebDAV root rather than a web admin path.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '遇到 401 或 403', 'Error 401 or 403'),
          body: syncText(
            context,
            '这通常是账号、密码或目录权限问题。重新确认账号是否允许 WebDAV，是否需要应用专用密码，以及目标目录是否允许写入。',
            'This is usually the account, the password or folder permissions. Check again whether the account may use WebDAV, whether an app-specific password is required, and whether the target folder is writable.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '遇到证书错误或超时',
            'Certificate errors or timeouts',
          ),
          body: syncText(
            context,
            '证书错误通常来自自签名证书、域名不匹配或证书过期；超时则优先检查 VPN、端口转发、防火墙和局域网隔离。',
            'Certificate errors usually come from a self-signed, mismatched or expired certificate. For timeouts, check VPN, port forwarding, firewall and network isolation first.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '只读成功但保存失败',
            'Reading works but saving fails',
          ),
          body: syncText(
            context,
            '说明读取权限存在，但创建目录、上传或删除权限不足。请给账号授予目标目录的完整 WebDAV 写权限，再重新测试。',
            'Reading is allowed but creating folders, uploading or deleting is not. Give the account full WebDAV write access to the target folder and test again.',
          ),
        ),
      ],
    ),
    ConnectionHelpSection(
      title: syncText(context, '安全注意事项', 'Security notes'),
      items: [
        ConnectionHelpItem(
          title: syncText(
            context,
            '不要在公共网络使用 HTTP',
            'Do not use HTTP on public networks',
          ),
          body: syncText(
            context,
            'HTTP 不会加密传输内容和 Basic Auth 凭据。公共 Wi-Fi、端口转发和不受信任的代理环境都不适合使用 HTTP。',
            'HTTP encrypts neither the content nor the Basic Auth credentials. Public Wi-Fi, port forwarding and untrusted proxies are all unsuitable for HTTP.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '不要把凭据放进截图或日志',
            'Keep credentials out of screenshots and logs',
          ),
          body: syncText(
            context,
            '分享问题截图时遮住服务器地址中的私密信息、用户名和所有可能识别家庭网络的内容。密码不会显示在页面上。',
            'When you share a screenshot, hide the private parts of the server address, the username and anything that identifies your home network. Passwords are never shown on screen.',
          ),
        ),
      ],
    ),
  ],
);

ConnectionHelpDocument _googleDriveDocument(
  BuildContext context,
) => ConnectionHelpDocument(
  title: 'Google Drive',
  intro: syncText(
    context,
    'Google Drive 使用系统浏览器完成 OAuth 授权。应用只保存授权引用，不在连接配置或日志中保存 Refresh Token。',
    'Google Drive signs in through the system browser with OAuth. The app keeps only a reference to that sign-in and never stores a refresh token in connection settings or logs.',
  ),
  sections: [
    ConnectionHelpSection(
      title: syncText(context, '开始前准备', 'Before you start'),
      items: [
        ConnectionHelpItem(
          title: syncText(
            context,
            '内置密钥或你自己的 Client ID',
            'The built-in key or your own Client ID',
          ),
          body: syncText(
            context,
            '如果这个版本内置了 Google 的应用密钥，直接登录即可。没有内置时（例如自己编译的版本），可以在 Google Cloud 免费创建一个自己的 OAuth Client ID，填到连接页的“使用自己的应用密钥”里。',
            'If this version has Google’s app key built in, just sign in. If it does not (for example a build you made yourself), create your own OAuth Client ID in Google Cloud for free and enter it under “Use your own app key” on the connection page.',
          ),
          bullets: [
            syncText(
              context,
              '在 Google Cloud 项目中启用 Drive API，配置 OAuth 同意屏幕，再创建 OAuth Client ID。',
              'In your Google Cloud project, enable the Drive API, configure the OAuth consent screen, then create an OAuth Client ID.',
            ),
            syncText(
              context,
              '移动端是公开客户端，只需要 Client ID，不需要也不要填写 Client Secret。',
              'Mobile apps are public clients: only the Client ID is needed, and no Client Secret should be entered.',
            ),
            syncText(
              context,
              '你自己的 Client ID 只保存在这台设备的系统安全存储中，不会上传。',
              'Your own Client ID is kept only in this device’s system secure storage and is never uploaded.',
            ),
            syncText(
              context,
              '测试账号、组织策略或未发布的同意屏幕，可能限制哪些账号可以登录。',
              'Test accounts, organization policies or an unpublished consent screen can limit which accounts may sign in.',
            ),
          ],
        ),
        ConnectionHelpItem(
          title: syncText(context, '登记回调地址', 'Register the redirect address'),
          body: syncText(
            context,
            '使用自己的 Client ID 时，授权完成后系统浏览器通过 velocksync://oauth/callback 把结果交回应用，Google Cloud 中登记的回调地址必须与它一致（连接页可以直接复制）。',
            'With your own Client ID, the system browser hands the result back to the app through velocksync://oauth/callback when sign-in finishes. The redirect registered in Google Cloud must match it exactly (you can copy it from the connection page).',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '确认访问范围', 'Check the access scope'),
          body: syncText(
            context,
            '当前实现使用 drive.file 范围：应用可以访问它创建的文件，以及用户在授权流程中明确选择或授予应用访问权的文件。',
            'This version uses the drive.file scope: the app can reach the files it creates, plus files the user picks or grants access to during sign-in.',
          ),
        ),
      ],
    ),
    ConnectionHelpSection(
      title: syncText(context, '页面字段怎么理解', 'What the fields mean'),
      items: [
        ConnectionHelpItem(
          title: syncText(context, '远端根目录 ID', 'Remote root folder ID'),
          body: syncText(
            context,
            '这是授权后浏览远端目录的起始位置。默认值 appDataFolder 指向 Google 为应用保留的隐藏安全空间，适合保存 Velock 的同步对象，不会把这些对象混在普通网盘文件中。',
            'This is where browsing starts after sign-in. The default appDataFolder points to the private space Google keeps for the app, which suits Velock sync items without mixing them into your ordinary Drive files.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '账号显示名称', 'Account display name'),
          body: syncText(
            context,
            '这是连接列表里显示给你的备注，不参与授权，也不会改变 Google 账号。留空时应用会使用授权账号或目录摘要。',
            'A label shown to you in the connection list. It takes no part in sign-in and never changes your Google account. If you leave it empty, the app uses the signed-in account or a folder summary.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '不要把文件夹网页链接当成 ID',
            'Do not paste a folder web link as the ID',
          ),
          body: syncText(
            context,
            '如果要从普通 Drive 文件夹开始，使用授权后提供的目录选择器选择它。不要直接把浏览器地址栏中的整段 URL 粘贴进根目录 ID。',
            'To start in an ordinary Drive folder, pick it in the folder chooser shown after sign-in. Do not paste the whole browser URL into the root folder ID.',
          ),
        ),
      ],
    ),
    ConnectionHelpSection(
      title: syncText(context, '完整操作流程', 'The full flow'),
      items: [
        ConnectionHelpItem(
          title: syncText(
            context,
            '点击保存并完成登录',
            'Tap Save and finish signing in',
          ),
          body: syncText(
            context,
            '应用会打开系统浏览器。选择正确的 Google 账号，查看权限请求并允许访问；不要在授权过程中关闭 Velock 或清理浏览器会话。',
            'The app opens the system browser. Pick the right Google account, review the permission request and allow it; do not close Velock or clear the browser session while signing in.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '选择同步目录', 'Choose the sync folder'),
          body: syncText(
            context,
            '回到应用后会打开远端目录选择器。最终保存的目录以选择器中的选择为准。',
            'Back in the app, the remote folder chooser opens. Whichever folder you pick there is the one that gets saved.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '等待连接检查完成', 'Wait for the connection check'),
          body: syncText(
            context,
            '应用会读取所选位置并检查是否可以作为同步目标。检查成功后，连接才会出现在“连接”页面。',
            'The app reads the chosen location and checks whether it can hold synced items. The connection appears on the “Connections” page only after that check succeeds.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '以后重新授权', 'Signing in again later'),
          body: syncText(
            context,
            '如果授权过期、撤销或账号策略变化，在连接详情页使用“重新授权”。不需要重新创建同步配置。',
            'If the sign-in expires, is revoked or your account policy changes, use “Authorize again” on the connection page. Nothing else has to be set up again.',
          ),
        ),
      ],
    ),
    ConnectionHelpSection(
      title: syncText(context, '常见问题', 'Common problems'),
      items: [
        ConnectionHelpItem(
          title: syncText(
            context,
            '连接页要求填写应用密钥',
            'The connection page asks for an app key',
          ),
          body: syncText(
            context,
            '说明这个版本没有内置 Google 的应用密钥。按上面的步骤创建自己的 Client ID 并填入；如果 Google 提示 redirect_uri_mismatch，检查回调地址是否与连接页显示的完全一致。',
            'This version has no built-in Google app key. Create your own Client ID as described above and enter it. If Google reports redirect_uri_mismatch, check that the redirect matches the one shown on the connection page exactly.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '登录后没有回到应用',
            'Sign-in does not return to the app',
          ),
          body: syncText(
            context,
            '检查自定义回调地址是否登记正确，系统是否允许 velocksync 链接唤起应用；如果浏览器停在空白页，返回应用查看是否已经收到回调。',
            'Check that the custom redirect is registered correctly and that the system lets velocksync links open the app. If the browser sits on a blank page, switch back to the app and see whether the result arrived.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '看不到目标文件夹', 'The target folder is missing'),
          body: syncText(
            context,
            '当前授权范围只显示应用有权访问的文件。确认你登录的是正确账号，并先在 Google Drive 中打开或授权目标文件夹。',
            'The current scope shows only the files the app may access. Check that you signed in with the right account, and open or grant the target folder in Google Drive first.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '授权成功但连接检查失败',
            'Sign-in works but the connection check fails',
          ),
          body: syncText(
            context,
            '检查 Drive API 是否启用、同意屏幕是否允许当前账号，以及网络是否能访问 Google API。若目录刚创建，稍等片刻后重新授权或重新测试。',
            'Check that the Drive API is enabled, that the consent screen allows this account and that the network can reach Google APIs. If the folder was just created, wait a moment and then sign in or test again.',
          ),
        ),
      ],
    ),
    ConnectionHelpSection(
      title: syncText(context, '隐私与安全', 'Privacy and security'),
      items: [
        ConnectionHelpItem(
          title: syncText(
            context,
            '令牌不会出现在连接配置里',
            'Tokens stay out of connection settings',
          ),
          body: syncText(
            context,
            'Access Token 和 Refresh Token 由系统安全存储管理。连接页面只展示账号、目录和状态等非敏感信息。',
            'Access and refresh tokens are held in system secure storage. The connection page shows only non-sensitive details such as account, folder and status.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '撤销访问', 'Revoke access'),
          body: syncText(
            context,
            '删除连接时应用会尝试撤销远端授权并清理本地凭据；如果网络暂时不可用，先不要反复删除重建，稍后重试更安全。',
            'When you delete a connection the app tries to revoke the sign-in and clear local credentials. If the network is down, do not delete and recreate in a loop; retrying later is safer.',
          ),
        ),
      ],
    ),
  ],
);

ConnectionHelpDocument _oneDriveDocument(
  BuildContext context,
) => ConnectionHelpDocument(
  title: 'OneDrive',
  intro: syncText(
    context,
    'OneDrive 使用 Microsoft 的系统浏览器授权流程。应用通过 Microsoft Graph 访问你选择的目录，并把令牌留在系统安全存储中。',
    'OneDrive signs in through the system browser with Microsoft. The app reaches the folder you choose through Microsoft Graph and keeps the tokens in system secure storage.',
  ),
  sections: [
    ConnectionHelpSection(
      title: syncText(context, '开始前准备', 'Before you start'),
      items: [
        ConnectionHelpItem(
          title: syncText(
            context,
            '内置密钥或你自己的应用',
            'The built-in key or your own app',
          ),
          body: syncText(
            context,
            '如果这个版本内置了 OneDrive 的应用密钥，直接登录即可。没有内置时，可以在 Microsoft Entra 管理中心免费注册一个公开客户端应用，把“应用程序（客户端）ID”填到连接页的“使用自己的应用密钥”里。应用不接受 Client Secret。',
            'If this version has OneDrive’s app key built in, just sign in. If it does not, register a public client app in the Microsoft Entra admin center for free and enter its Application (client) ID under “Use your own app key” on the connection page. The app accepts no Client Secret.',
          ),
          bullets: [
            syncText(
              context,
              '填写的是 Application (client) ID，不是 Directory (tenant) ID。',
              'Enter the Application (client) ID, not the Directory (tenant) ID.',
            ),
            syncText(
              context,
              '根据组织策略选择允许的账号类型；个人账号和工作/学校账号的可用范围可能不同。',
              'Choose the account types your organization policy allows; personal and work or school accounts can differ in what they may reach.',
            ),
            syncText(
              context,
              '如果租户要求管理员同意 Files.ReadWrite 或 offline_access，需要先完成管理员同意。',
              'If the tenant requires administrator consent for Files.ReadWrite or offline_access, that consent has to be granted first.',
            ),
          ],
        ),
        ConnectionHelpItem(
          title: syncText(context, '登记回调地址', 'Register the redirect address'),
          body: syncText(
            context,
            '使用自己的应用时，授权完成后系统浏览器通过 velocksync://oauth/callback 回到应用。Entra 应用注册中的“移动和桌面应用程序”回调必须与这个地址一致（连接页可以直接复制）。',
            'With your own app, the system browser returns to the app through velocksync://oauth/callback when sign-in finishes. The “Mobile and desktop applications” redirect in the Entra app registration must match this address (you can copy it from the connection page).',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '确认 Graph 权限',
            'Check the Graph permissions',
          ),
          body: syncText(
            context,
            '当前实现请求 Files.ReadWrite 和 offline_access，用于读写同步对象并在下次使用时刷新访问令牌。组织管理员可能需要批准这些权限。',
            'This version requests Files.ReadWrite and offline_access so it can read and write synced items and refresh the access token later. An administrator may need to approve these permissions.',
          ),
        ),
      ],
    ),
    ConnectionHelpSection(
      title: syncText(context, '页面字段怎么理解', 'What the fields mean'),
      items: [
        ConnectionHelpItem(
          title: syncText(context, '远端根目录 ID', 'Remote root folder ID'),
          body: syncText(
            context,
            '这是目录选择器开始浏览的位置。默认 root 表示当前账号的 OneDrive 根目录；你也可以填入一个已知目录 ID，让选择器从该位置开始。最终保存的目录以授权后的选择为准。',
            'This is where the folder chooser starts. The default root means the OneDrive root of the signed-in account; you can also enter a known folder ID to start there. The folder you pick after signing in is the one that gets saved.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '账号显示名称', 'Account display name'),
          body: syncText(
            context,
            '这是连接列表中的可读备注，只用于区分多个 OneDrive 连接。留空不会影响授权或同步。',
            'A readable label in the connection list, used only to tell several OneDrive connections apart. Leaving it empty affects neither sign-in nor syncing.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '根目录和同步目录不是一回事',
            'The root is not the sync folder',
          ),
          body: syncText(
            context,
            'root 只是浏览起点，不代表应用一定把数据写在 OneDrive 根目录。完成授权后，请在目录选择器中确认真正要用于同步的位置。',
            'root is only a starting point for browsing; it does not mean data is written to the OneDrive root. After signing in, confirm the folder you really want to sync in the chooser.',
          ),
        ),
      ],
    ),
    ConnectionHelpSection(
      title: syncText(context, '完整操作流程', 'The full flow'),
      items: [
        ConnectionHelpItem(
          title: syncText(context, '点击保存并登录', 'Tap Save and sign in'),
          body: syncText(
            context,
            '应用会打开系统浏览器。使用正确的 Microsoft 账号登录，确认租户和权限后同意访问。不要在授权途中关闭应用。',
            'The app opens the system browser. Sign in with the right Microsoft account, check the tenant and permissions, then allow access. Do not close the app while signing in.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '选择同步目录', 'Choose the sync folder'),
          body: syncText(
            context,
            '回到应用后进入 OneDrive 目录选择器。可以进入子目录，也可以返回上一级；选择完成后，当前目录会成为同步目标。',
            'Back in the app, the OneDrive folder chooser opens. You can enter subfolders or go up one level; whichever folder you finish on becomes the sync target.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '等待连接检查完成', 'Wait for the connection check'),
          body: syncText(
            context,
            '应用会读取所选目录并验证 Graph 访问权限。检查成功后才会保存连接并回到“连接”页面。',
            'The app reads the chosen folder and verifies Graph access. The connection is saved and you return to the “Connections” page only after that succeeds.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '以后重新授权', 'Signing in again later'),
          body: syncText(
            context,
            '当管理员策略改变、令牌失效或账号撤销授权时，在连接详情页使用“重新授权”，不需要重新填写同步配置。',
            'If an administrator changes policy, the token stops working or the account revokes access, use “Authorize again” on the connection page. Nothing else has to be filled in again.',
          ),
        ),
      ],
    ),
    ConnectionHelpSection(
      title: syncText(context, '常见问题', 'Common problems'),
      items: [
        ConnectionHelpItem(
          title: syncText(
            context,
            '连接页要求填写应用密钥',
            'The connection page asks for an app key',
          ),
          body: syncText(
            context,
            '说明这个版本没有内置 OneDrive 的应用密钥。按上面的步骤注册自己的应用并填入 Application (client) ID，注意不要填成 Directory (tenant) ID。',
            'This version has no built-in OneDrive app key. Register your own app as described above and enter its Application (client) ID — not the Directory (tenant) ID.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '提示重定向地址不匹配',
            '“Redirect address does not match”',
          ),
          body: syncText(
            context,
            '重新检查 Entra 应用注册的平台类型和回调地址。地址必须使用 velocksync://oauth/callback，协议、主机和路径都不能改。',
            'Check the platform type and redirect address in the Entra app registration again. It must be velocksync://oauth/callback; scheme, host and path cannot change.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '目录列表为空或无法打开',
            'The folder list is empty or will not open',
          ),
          body: syncText(
            context,
            '确认登录账号对该目录有访问权，并确认组织的条件访问策略没有阻止移动端公共客户端。必要时让管理员重新授予 Files.ReadWrite 同意。',
            'Check that the signed-in account may reach the folder and that the organization conditional access policy does not block mobile public clients. If needed, ask an administrator to grant Files.ReadWrite consent again.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '授权成功但连接检查失败',
            'Sign-in works but the connection check fails',
          ),
          body: syncText(
            context,
            '检查 Microsoft Graph 服务状态、账号租户策略和网络；如果目录刚刚创建或权限刚刚变更，等待几秒后重新授权通常比连续点击保存更有效。',
            'Check Microsoft Graph status, your tenant policy and the network. If the folder or its permissions just changed, waiting a few seconds and signing in again works better than tapping Save repeatedly.',
          ),
        ),
      ],
    ),
    ConnectionHelpSection(
      title: syncText(context, '隐私与安全', 'Privacy and security'),
      items: [
        ConnectionHelpItem(
          title: syncText(
            context,
            '令牌由系统安全存储保管',
            'Tokens are held in system secure storage',
          ),
          body: syncText(
            context,
            'Access Token 和 Refresh Token 不会显示在界面、连接 JSON 或普通日志中。同步只使用当前账号获得的授权范围。',
            'Access and refresh tokens never appear on screen, in connection JSON or in ordinary logs. Syncing uses only the access the current account was granted.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '组织策略优先', 'Organization policy wins'),
          body: syncText(
            context,
            '工作或学校账号可能受到租户管理员、条件访问和数据位置策略限制。应用无法绕过这些策略，需要在 Entra 管理端完成配置。',
            'Work or school accounts can be limited by tenant administrators, conditional access and data location policies. The app cannot bypass them; the settings have to be completed in Entra.',
          ),
        ),
      ],
    ),
  ],
);

ConnectionHelpDocument _baiduNetdiskDocument(
  BuildContext context,
) => ConnectionHelpDocument(
  title: syncText(context, '百度网盘', 'Baidu Netdisk'),
  intro: syncText(
    context,
    '用百度账号登录授权后，Sync 通过百度网盘开放平台读写文件。如果这个版本内置了百度的应用密钥，直接登录即可；否则需要先免费注册一个自己的应用。',
    'Sign in with your Baidu account and Sync reads and writes files through the Baidu Netdisk open platform. If this version has Baidu’s app key built in, just sign in; otherwise register your own app first, for free.',
  ),
  sections: [
    ConnectionHelpSection(
      title: syncText(context, '怎么连接', 'How to connect'),
      items: [
        ConnectionHelpItem(
          title: syncText(context, '登录并同意授权', 'Sign in and approve'),
          body: syncText(
            context,
            '点击“登录并选择保存位置”后会打开百度的登录页。登录并同意后回到 Sync，再选择保存位置。',
            'Tap “Sign in and choose a location” to open Baidu’s sign-in page. After you sign in and approve, return to Sync and choose where to save.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '没有内置密钥时：使用自己的应用',
            'Without a built-in key: use your own app',
          ),
          body: syncText(
            context,
            '在百度网盘开放平台登录并创建一个应用，然后把下面三项填到连接页的“使用自己的应用密钥”里。它们只保存在这台设备的系统安全存储中。',
            'Sign in to the Baidu Netdisk open platform and create an app, then enter these three values under “Use your own app key” on the connection page. They stay only in this device’s system secure storage.',
          ),
          bullets: [
            syncText(
              context,
              'AppKey 与 SecretKey：在应用详情里可以看到。SecretKey 百度每次续期登录都要用，所以会和这个连接的授权一起保存。',
              'AppKey and SecretKey: shown on the app’s details page. Baidu needs the SecretKey every time the sign-in is renewed, so it is stored with this connection’s sign-in.',
            ),
            syncText(
              context,
              '应用名称：百度只允许这个应用写入“我的应用数据”下以它命名的文件夹，所以要填写与开放平台上完全一致的名称。',
              'App name: Baidu only lets the app write to the folder named after it under “My app data”, so enter it exactly as shown on the open platform.',
            ),
            syncText(
              context,
              '授权回调地址填写 velocksync://oauth/callback（连接页可以直接复制）。',
              'Set the redirect address to velocksync://oauth/callback (you can copy it from the connection page).',
            ),
          ],
        ),
        ConnectionHelpItem(
          title: syncText(context, '推荐使用 Sync 专用文件夹', 'Use Sync’s app folder'),
          body: syncText(
            context,
            '百度网盘通常只允许第三方应用写入“我的应用数据”下的专属文件夹：内置密钥是 $baiduNetdiskAppFolder，自己的应用是 /apps/<应用名称>。选别的文件夹时，读取可能正常，但上传会被百度拒绝。',
            'Baidu Netdisk usually only lets third-party apps write to their own folder under “My app data”: $baiduNetdiskAppFolder with the built-in key, or /apps/<app name> with your own app. Other folders may be readable, but Baidu can refuse uploads there.',
          ),
        ),
      ],
    ),
    ConnectionHelpSection(
      title: syncText(context, '需要知道的事', 'Good to know'),
      items: [
        ConnectionHelpItem(
          title: syncText(context, '登录信息', 'Sign-in details'),
          body: syncText(
            context,
            '授权凭据只保存在系统安全存储中，不会出现在连接设置、同步内容或日志里。删除连接时一并删除。',
            'Sign-in credentials are kept only in system secure storage, never in connection settings, synced content or logs. They are removed with the connection.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '大文件', 'Large files'),
          body: syncText(
            context,
            '文件按 4 MB 分片上传。上传中断后，下一次会从头重新上传。',
            'Files upload in 4 MB pieces. If an upload is interrupted, the next attempt starts over.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '授权失效', 'When sign-in expires'),
          body: syncText(
            context,
            '如果提示需要重新授权，在连接列表的“更多操作”里选择“修改连接”重新登录即可，已选的保存位置不变。',
            'If you are asked to sign in again, choose “Edit Connection” from the connection’s More menu. The chosen location stays the same.',
          ),
        ),
      ],
    ),
  ],
);

ConnectionHelpDocument _aliyunDriveDocument(
  BuildContext context,
) => ConnectionHelpDocument(
  title: syncText(context, '阿里云盘', 'Aliyun Drive'),
  intro: syncText(
    context,
    '用阿里云盘账号登录授权后，Sync 通过阿里云盘开放平台读写文件。如果这个版本内置了阿里云盘的应用密钥，直接登录即可；否则需要先免费注册一个自己的应用。',
    'Sign in with your Aliyun Drive account and Sync reads and writes files through the Aliyun Drive open platform. If this version has Aliyun Drive’s app key built in, just sign in; otherwise register your own app first, for free.',
  ),
  sections: [
    ConnectionHelpSection(
      title: syncText(context, '怎么连接', 'How to connect'),
      items: [
        ConnectionHelpItem(
          title: syncText(context, '登录并同意授权', 'Sign in and approve'),
          body: syncText(
            context,
            '点击“登录并选择保存位置”后会打开阿里云盘的授权页。同意后回到 Sync，再选择一个文件夹保存。',
            'Tap “Sign in and choose a location” to open Aliyun Drive’s approval page. After you approve, return to Sync and choose a folder.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '没有内置密钥时：使用自己的应用',
            'Without a built-in key: use your own app',
          ),
          body: syncText(
            context,
            '在阿里云盘开放平台创建一个应用，把 App ID 填到连接页的“使用自己的应用密钥”里；App Secret 可以不填。授权回调地址填写 velocksync://oauth/callback（连接页可以直接复制）。这些信息只保存在这台设备的系统安全存储中。',
            'Create an app on the Aliyun Drive open platform and enter its App ID under “Use your own app key” on the connection page; the App Secret is optional. Set the redirect address to velocksync://oauth/callback (you can copy it from the connection page). These values stay only in this device’s system secure storage.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '选一个单独的文件夹', 'Pick a dedicated folder'),
          body: syncText(
            context,
            '建议新建一个空文件夹专门给 Sync 使用，不要直接选网盘根目录。',
            'Create an empty folder just for Sync rather than using the drive’s top level.',
          ),
        ),
      ],
    ),
    ConnectionHelpSection(
      title: syncText(context, '需要知道的事', 'Good to know'),
      items: [
        ConnectionHelpItem(
          title: syncText(context, '登录信息', 'Sign-in details'),
          body: syncText(
            context,
            '授权凭据只保存在系统安全存储中，不会出现在连接设置、同步内容或日志里。删除连接时一并删除。',
            'Sign-in credentials are kept only in system secure storage, never in connection settings, synced content or logs. They are removed with the connection.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '大文件', 'Large files'),
          body: syncText(
            context,
            '文件按 8 MB 分片上传。上传中断后，下一次会从头重新上传。',
            'Files upload in 8 MB pieces. If an upload is interrupted, the next attempt starts over.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '授权失效', 'When sign-in expires'),
          body: syncText(
            context,
            '如果提示需要重新授权，在连接列表的“更多操作”里选择“修改连接”重新登录即可，已选的保存位置不变。',
            'If you are asked to sign in again, choose “Edit Connection” from the connection’s More menu. The chosen location stays the same.',
          ),
        ),
      ],
    ),
  ],
);
