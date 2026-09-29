import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
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
class ConnectionHelpPage extends StatelessWidget {
  const ConnectionHelpPage({super.key, this.providerType});

  final RemoteProviderType? providerType;

  @override
  Widget build(BuildContext context) {
    final documents = providerType == null
        ? [
            _webDavDocument(context),
            _googleDriveDocument(context),
            _oneDriveDocument(context),
            _baiduNetdiskDocument(context),
            _aliyunDriveDocument(context),
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
      actions: providerType == RemoteProviderType.baiduNetdisk
          ? [
              AdaptiveTextButton(
                padding: EdgeInsets.zero,
                onPressed: () =>
                    context.pushNamed(AppRoutes.newBaiduToken.name),
                child: Text(syncText(context, '配置 Token', 'Configure token')),
              ),
            ]
          : const [],
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
            '准备公开 OAuth Client ID',
            'Prepare a public OAuth Client ID',
          ),
          body: syncText(
            context,
            '在 Google Cloud 项目中启用 Drive API，配置 OAuth 同意屏幕并创建 OAuth Client ID。移动端使用公开客户端，不需要、也不应该把 Client Secret 放进应用。',
            'In your Google Cloud project, enable the Drive API, configure the OAuth consent screen and create an OAuth Client ID. Mobile apps use a public client, so a Client Secret is neither needed nor safe to put in the app.',
          ),
          bullets: [
            syncText(
              context,
              '将 Client ID 作为构建参数 GOOGLE_OAUTH_CLIENT_ID 传入。',
              'Pass the Client ID as the build option GOOGLE_OAUTH_CLIENT_ID.',
            ),
            syncText(
              context,
              '没有传入 Client ID 时，页面会显示“授权未就绪”，保存按钮不会开始授权。',
              'Without a Client ID the page shows “Authorization not ready” and Save does not start the sign-in.',
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
            '授权完成后，系统浏览器通过 velocksync://oauth/callback 把结果交回应用。Google Cloud 中登记的回调配置必须与构建版本使用的地址一致。',
            'When sign-in finishes, the system browser hands the result back to the app through velocksync://oauth/callback. The redirect registered in Google Cloud must match the address your build uses.',
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
          title: syncText(context, '提示授权未就绪', '“Authorization not ready”'),
          body: syncText(
            context,
            '检查构建命令是否包含 --dart-define=GOOGLE_OAUTH_CLIENT_ID=你的客户端 ID，并确认使用的是正确环境的构建产物。',
            'Check that the build command includes --dart-define=GOOGLE_OAUTH_CLIENT_ID=your client ID, and that you are running a build made for the right environment.',
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
          title: syncText(context, '创建公开客户端应用', 'Create a public client app'),
          body: syncText(
            context,
            '在 Microsoft Entra 管理中心注册应用，使用适合移动端的公开客户端配置。应用不接受 Client Secret，也不会把 Secret 编译进客户端。',
            'Register the app in the Microsoft Entra admin center with a public client configuration for mobile. The app accepts no Client Secret and never compiles one into the client.',
          ),
          bullets: [
            syncText(
              context,
              '将 Application (client) ID 作为构建参数 ONEDRIVE_OAUTH_CLIENT_ID 传入。',
              'Pass the Application (client) ID as the build option ONEDRIVE_OAUTH_CLIENT_ID.',
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
            '授权完成后，系统浏览器通过 velocksync://oauth/callback 回到应用。Entra 应用注册中的移动端回调配置必须与这个地址一致。',
            'When sign-in finishes, the system browser returns to the app through velocksync://oauth/callback. The mobile redirect in the Entra app registration must match this address.',
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
          title: syncText(context, '提示授权未就绪', '“Authorization not ready”'),
          body: syncText(
            context,
            '检查构建命令是否包含 --dart-define=ONEDRIVE_OAUTH_CLIENT_ID=你的 Application (client) ID，并确认没有把 Directory (tenant) ID 填错。',
            'Check that the build command includes --dart-define=ONEDRIVE_OAUTH_CLIENT_ID=your Application (client) ID, and that the Directory (tenant) ID was not mixed up with it.',
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
    '百度网盘的 OAuth 文档提供授权码、简化和设备码三种模式。当前页面可以把你已经取得的 AppKey、Token 和可选 SecretKey 保存到系统安全存储，但这不等于已经创建了可同步连接。',
    'Baidu Netdisk documents three OAuth modes: authorization code, implicit and device code. This page can save an AppKey, token and optional SecretKey you already obtained into system secure storage, but that does not create a connection you can sync with.',
  ),
  sections: [
    ConnectionHelpSection(
      title: syncText(context, '先说清楚当前状态', 'Where things stand'),
      items: [
        ConnectionHelpItem(
          title: syncText(
            context,
            '“配置 Token”能做什么',
            'What “Configure token” does',
          ),
          body: syncText(
            context,
            '它会把百度 OAuth 凭据保存到当前设备的系统安全存储中，避免凭据进入普通偏好设置、连接 JSON、同步包或诊断日志。再次打开页面时，已保存的字段会回填到表单中。',
            'It saves the Baidu OAuth credentials into system secure storage on this device, so they stay out of ordinary preferences, connection JSON, sync packages and diagnostic logs. Reopening the page fills the saved fields back into the form.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '为什么之前显示“暂不可用”',
            'Why it used to say “Not available yet”',
          ),
          body: syncText(
            context,
            '这不是说百度网盘账号不能授权，而是当前仓库还没有百度网盘 RemoteObjectStore 适配器，连接状态检查和实际上传/下载还没有实现。同时，百度官方设备码、授权码和刷新 Token 的请求都要求 SecretKey；把这个密钥编译进移动端并不安全。',
            'That message did not mean a Baidu account cannot be authorized: this build has no Baidu storage adapter yet, so connection checks and real uploads or downloads are missing. On top of that, Baidu device-code, authorization-code and token-refresh requests all require the SecretKey, and compiling that key into a mobile app is not safe.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '保存后为什么不会出现在连接列表',
            'Why saving does not add a connection',
          ),
          body: syncText(
            context,
            '凭据配置页只保存 Token，不创建一个无法执行同步的假连接。等百度适配器和受信任的 Token Broker 完成后，才会把这组凭据接入真正的连接向导。',
            'This page only stores tokens; it does not create a fake connection that cannot sync. Once a Baidu adapter and a trusted token broker exist, these credentials will be wired into the real connection flow.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '什么时候才算真正支持', 'What real support requires'),
          body: syncText(
            context,
            '至少需要百度网盘 RemoteObjectStore、统一对象存储契约测试、401/403/429 等错误映射，以及不把 SecretKey 暴露给移动端的授权或 Token Broker 流程。',
            'At the very least: a Baidu storage adapter, the shared storage contract tests, error mapping for 401/403/429, and a sign-in or token broker flow that does not expose the SecretKey to the mobile app.',
          ),
        ),
      ],
    ),
    ConnectionHelpSection(
      title: syncText(
        context,
        '在百度官方平台准备应用',
        'Prepare an app on the Baidu platform',
      ),
      items: [
        ConnectionHelpItem(
          title: syncText(
            context,
            '进入百度网盘开放平台控制台',
            'Open the Baidu Netdisk developer console',
          ),
          body: syncText(
            context,
            '官方控制台入口：https://pan.baidu.com/union/console/applist?from=doc_header。登录百度账号后，在应用列表中创建或选择应用。',
            'Console: https://pan.baidu.com/union/console/applist?from=doc_header. Sign in with your Baidu account, then create or pick an app in the app list.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '记录 AppKey 和 SecretKey',
            'Note the AppKey and SecretKey',
          ),
          body: syncText(
            context,
            'AppKey 是应用标识，SecretKey 是应用密钥。AppKey 可以作为客户端标识使用；SecretKey 属于机密信息，不要提交到代码仓库、截图、构建参数、崩溃日志或聊天记录。',
            'The AppKey identifies your app and the SecretKey is its secret. The AppKey can act as the client identifier, but the SecretKey must never go into a repository, screenshot, build option, crash log or chat message.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '申请网盘权限', 'Request Netdisk access'),
          body: syncText(
            context,
            '百度官方示例使用 scope=basic,netdisk。实际 Token 返回的 scope 还会受到应用配置和用户同意结果影响；页面中的 Scope 至少要包含 netdisk，否则不能代表网盘访问授权。',
            'Baidu examples use scope=basic,netdisk. The scope a token really returns also depends on your app configuration and what the user agreed to; the Scope field here must include netdisk, or it does not stand for Netdisk access.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '需要回调地址时按控制台原值填写',
            'Use the console value for the redirect address',
          ),
          body: syncText(
            context,
            '授权码模式要求 redirect_uri 与百度控制台设置完全一致。百度文档还允许无 Server 应用使用 redirect_uri=oob；不要把 Velock 的 velocksync:// 回调地址直接填给百度，除非百度控制台和当前授权流程都明确支持并登记了它。',
            'The authorization-code mode requires redirect_uri to match the Baidu console exactly. Baidu also allows redirect_uri=oob for apps without a server; do not give Baidu the Velock velocksync:// address unless the console and the flow you use both support and register it.',
          ),
        ),
      ],
    ),
    ConnectionHelpSection(
      title: syncText(
        context,
        '官方三种授权方式怎么选',
        'Choosing among the three sign-in modes',
      ),
      items: [
        ConnectionHelpItem(
          title: syncText(
            context,
            '授权码模式：适合有服务端的正式接入',
            'Authorization code: for a server-backed setup',
          ),
          body: syncText(
            context,
            '先访问 authorize 接口取得 code，再由服务端调用 token 接口换取 access_token、expires_in 和 refresh_token。code 只能使用一次，10 分钟未使用会过期；换 Token 时需要 AppKey、SecretKey 和完全匹配的 redirect_uri。',
            'Call the authorize endpoint for a code, then have your server call the token endpoint for access_token, expires_in and refresh_token. A code works once and expires after 10 minutes unused; exchanging it needs the AppKey, the SecretKey and an exactly matching redirect_uri.',
          ),
          bullets: [
            syncText(
              context,
              '官方授权入口示例：https://openapi.baidu.com/oauth/2.0/authorize?response_type=code&client_id=AppKey&redirect_uri=回调地址&scope=basic,netdisk。',
              'Example authorize URL: https://openapi.baidu.com/oauth/2.0/authorize?response_type=code&client_id=AppKey&redirect_uri=<redirect uri>&scope=basic,netdisk.',
            ),
            syncText(
              context,
              '如果 code 已经使用过或已过期，不要重复提交，重新发起授权。',
              'If the code was already used or has expired, do not resubmit it; start the sign-in again.',
            ),
          ],
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '简化模式：只有短期 Access Token',
            'Implicit: a short-lived access token only',
          ),
          body: syncText(
            context,
            '把 response_type 设为 token，授权后直接从回调结果中取得 access_token 和 expires_in。百度 FAQ 明确说明，这种模式有效期较短且不支持刷新，过期后必须重新登录授权。',
            'With response_type set to token, the access_token and expires_in come straight back in the redirect. Baidu FAQ states this mode is short-lived and cannot be refreshed, so signing in again is required once it expires.',
          ),
          bullets: [
            syncText(
              context,
              '适合临时验证，不适合长期无人值守同步。',
              'Fine for a quick check; not for long unattended syncing.',
            ),
            syncText(
              context,
              '如果你只有这一类 Token，页面可以只填写 AppKey 和 Access Token，SecretKey、Refresh Token 与过期时间可以留空。',
              'If this is the only token you have, fill in just the AppKey and Access Token; SecretKey, Refresh Token and the expiry may stay empty.',
            ),
          ],
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '设备码模式：适合无回调或输入受限的设备',
            'Device code: for devices without a redirect or with limited input',
          ),
          body: syncText(
            context,
            '先用 AppKey 请求 device_code、user_code、verification_url 和 qrcode_url，让用户在浏览器或手机完成授权；再用 device_code 轮询 token 接口。官方示例返回 expires_in=300 秒、interval=5 秒，轮询间隔不要低于 5 秒。',
            'Request device_code, user_code, verification_url and qrcode_url with the AppKey so the user can approve in a browser or on a phone, then poll the token endpoint with the device_code. Baidu example returns expires_in=300 seconds and interval=5 seconds; do not poll more often than every 5 seconds.',
          ),
          bullets: [
            syncText(
              context,
              '换 Token 的 grant_type 是 device_token，并且官方文档要求提交 SecretKey。',
              'The exchange uses grant_type=device_token, and the official documentation requires the SecretKey with it.',
            ),
            syncText(
              context,
              '成功后通常会得到有效期 30 天的 access_token 和可刷新的 refresh_token。',
              'On success you usually get an access_token valid for 30 days and a refreshable refresh_token.',
            ),
            syncText(
              context,
              'refresh_token 只能使用一次；刷新响应返回的新 refresh_token 必须替换旧值。',
              'A refresh_token works once; the new refresh_token in the response must replace the old value.',
            ),
          ],
        ),
      ],
    ),
    ConnectionHelpSection(
      title: syncText(
        context,
        'Token 配置页每个字段怎么填',
        'What each field on the token page means',
      ),
      items: [
        ConnectionHelpItem(
          title: 'AppKey',
          body: syncText(
            context,
            '必填。填写百度控制台中应用的 AppKey，不要填应用名称、AppID 或整段授权 URL。它用于标识是哪一个百度应用获得了授权。',
            'Required. Enter the AppKey of your app in the Baidu console, not the app name, the AppID or a whole authorize URL. It identifies which Baidu app was authorized.',
          ),
        ),
        ConnectionHelpItem(
          title: 'SecretKey',
          body: syncText(
            context,
            '当前为可选字段。简化模式只需要已有 Access Token 时可以留空；设备码换 Token、授权码换 Token 或刷新 Token 时，百度官方流程需要它。输入后只保存在系统安全存储中，但移动端仍不能把它当作真正不可提取的机密。',
            'Optional here. Leave it empty in implicit mode when you already have an access token; the official Baidu flows need it for device-code exchange, authorization-code exchange and token refresh. It is saved only in system secure storage, but on a mobile device it still cannot be treated as a secret that can never be extracted.',
          ),
        ),
        ConnectionHelpItem(
          title: 'Access Token',
          body: syncText(
            context,
            '必填。只粘贴 Token 值本身，不要带 Bearer 前缀、引号、换行或参数名 access_token=。它代表用户授予应用的当前访问凭证。',
            'Required. Paste only the token value: no Bearer prefix, quotes, line breaks or access_token= parameter name. It is the current credential the user granted your app.',
          ),
        ),
        ConnectionHelpItem(
          title: 'Refresh Token',
          body: syncText(
            context,
            '可选。授权码或设备码模式通常会返回它；简化模式不支持刷新。百度的 refresh_token 是一次性轮换值，每次刷新成功后必须把新值覆盖旧值，否则下次刷新会失败。',
            'Optional. Authorization-code and device-code modes usually return one; implicit mode cannot refresh. The Baidu refresh_token rotates and works once, so each successful refresh must overwrite the old value or the next refresh fails.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, 'Access Token 过期时间', 'Access Token expiry'),
          body: syncText(
            context,
            '可选，使用 ISO 8601 时间，例如 2026-08-07T12:00:00Z。官方返回 expires_in 时可以根据当前时间换算；不知道准确时间时留空，不要凭感觉填一个很远的日期。',
            'Optional, in ISO 8601, for example 2026-08-07T12:00:00Z. If Baidu returns expires_in you can work it out from the current time; if you do not know it, leave it empty instead of guessing a far-off date.',
          ),
        ),
        ConnectionHelpItem(
          title: 'Scope',
          body: syncText(
            context,
            '默认填写 basic,netdisk。可以用逗号或空格分隔，但必须包含 netdisk。页面中的 Scope 只是记录 Token 的授权范围，不会替你向百度申请新的权限。',
            'Defaults to basic,netdisk. Commas or spaces both work, but it must include netdisk. The Scope here only records what the token was granted; it does not request new permissions from Baidu for you.',
          ),
        ),
      ],
    ),
    ConnectionHelpSection(
      title: syncText(context, '保存和排错', 'Saving and troubleshooting'),
      items: [
        ConnectionHelpItem(
          title: syncText(context, '保存按钮做什么', 'What Save does'),
          body: syncText(
            context,
            '保存按钮只校验必填字段、Scope 和可选的日期格式，然后把凭据写入系统安全存储。它不会调用百度 API，也不会创建连接或开始同步。',
            'Save checks the required fields, the Scope and the optional date format, then writes the credentials to system secure storage. It calls no Baidu API and creates no connection or syncing.',
          ),
        ),
        ConnectionHelpItem(
          title: 'redirect_uri_mismatch',
          body: syncText(
            context,
            '百度返回这个错误时，通常是授权请求里的 redirect_uri 与控制台安全设置不完全一致。逐字符检查协议、域名、端口、路径、大小写和尾部斜杠；如果是 oob 流程，确保使用的是官方允许的 oob 值。',
            'This error usually means the redirect_uri in the authorize request does not exactly match the console security setting. Compare scheme, domain, port, path, letter case and trailing slash character by character; for an oob flow, make sure you use the oob value Baidu allows.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            'invalid_client 或 SecretKey 错误',
            'invalid_client or a SecretKey error',
          ),
          body: syncText(
            context,
            '确认 AppKey 和 SecretKey 属于同一个应用，且没有把 AppID、应用名称或复制时带入的空格当成 SecretKey。不要为了排错把 SecretKey 写入日志。',
            'Check that the AppKey and SecretKey belong to the same app, and that an AppID, an app name or a space picked up while copying was not used as the SecretKey. Never write the SecretKey to a log to troubleshoot.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            'code 或 device_code 失效',
            'code or device_code no longer works',
          ),
          body: syncText(
            context,
            '授权码只能用一次并在 10 分钟后过期；device_code 默认只在返回的 expires_in 内有效。重新发起授权，不要重复轮询已经过期的 code。',
            'An authorization code works once and expires after 10 minutes; a device_code is valid only for the returned expires_in. Start the sign-in again instead of polling an expired code.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            'refresh_token 刷新失败',
            'refresh_token refresh fails',
          ),
          body: syncText(
            context,
            '先确认没有并发刷新同一值。百度要求 refresh_token 一次性使用，成功响应中的新 refresh_token 要替换旧值；如果刷新请求失败，官方建议重新发起授权，而不是循环重试旧值。',
            'First check that the same value is not being refreshed twice at once. Baidu requires one-time use of a refresh_token, and the new refresh_token in a successful response replaces the old one; if a refresh fails, Baidu advises starting the sign-in again rather than retrying the old value in a loop.',
          ),
        ),
      ],
    ),
    ConnectionHelpSection(
      title: syncText(context, '安全边界', 'Security limits'),
      items: [
        ConnectionHelpItem(
          title: syncText(
            context,
            'Token 等同于用户网盘操作凭据',
            'A token acts as the user credential for the drive',
          ),
          body: syncText(
            context,
            '百度 FAQ 明确不推荐把 access_token 分发给多个客户端，因为泄露后他人可以操作用户网盘内容。不要把 Token 粘贴到工单、群聊、截图、同步包或公开仓库。',
            'Baidu FAQ advises against handing one access_token to several clients, because anyone who obtains it can act on the user Netdisk content. Never paste a token into a ticket, group chat, screenshot, sync package or public repository.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            'SecretKey 不适合放进公共移动应用',
            'A SecretKey does not belong in a public mobile app',
          ),
          body: syncText(
            context,
            '只要 SecretKey 在移动端运行时可用，就不能保证永远不被提取。个人测试可以在你信任的设备上临时配置；正式多人使用应通过独立、最小权限的 Token Broker 完成授权和刷新。',
            'As long as a SecretKey is available at runtime on a phone, it cannot be guaranteed to stay hidden. Personal testing can set it up temporarily on a device you trust; wider use should go through a separate, least-privilege token broker for sign-in and refresh.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '官方文档入口', 'Official documentation'),
          body: syncText(
            context,
            '百度网盘开放平台文档：https://pan.baidu.com/union/doc/；授权介绍：https://pan.baidu.com/union/doc/使用入门/接入授权/授权介绍/；设备码模式：https://pan.baidu.com/union/doc/使用入门/接入授权/设备码模式授权/；接入 access_token FAQ：https://pan.baidu.com/union/doc/faq/接入access_token/。',
            'Baidu Netdisk developer documentation: https://pan.baidu.com/union/doc/; authorization: https://pan.baidu.com/union/doc/使用入门/接入授权/授权介绍/; device code: https://pan.baidu.com/union/doc/使用入门/接入授权/设备码模式授权/; access_token FAQ: https://pan.baidu.com/union/doc/faq/接入access_token/.',
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
    '阿里云盘当前没有在应用中开放连接或 Token 配置入口。官方 PDS 文档描述的是 WebServer OAuth 应用，涉及应用 ID、Secret、域和回调地址，不能安全地直接塞进移动客户端。',
    'Aliyun Drive has no connection or token setup in this app. The official PDS documentation describes WebServer OAuth apps that involve an app ID, a secret, a domain and a redirect address, which cannot safely be placed in a mobile client.',
  ),
  sections: [
    ConnectionHelpSection(
      title: syncText(context, '当前状态', 'Current status'),
      items: [
        ConnectionHelpItem(
          title: syncText(
            context,
            '为什么没有 Token 输入框',
            'Why there is no token form',
          ),
          body: syncText(
            context,
            '项目当前没有阿里云盘 RemoteObjectStore，也没有经过审核的 Token Broker。直接让移动端保存 App Secret 并宣称可以同步，会绕过官方应用安全边界，因此暂不开放配置。',
            'This project has no Aliyun Drive storage adapter and no reviewed token broker. Letting a phone store the App Secret and claiming syncing works would step around the official app security boundary, so setup stays closed for now.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '正式开放前需要什么',
            'What it needs before it can open',
          ),
          body: syncText(
            context,
            '需要完成 PDS 对象存储适配器、统一契约测试、权限和错误映射，并通过只接收短期授权材料的独立 Token Broker 处理授权码、刷新和撤销。',
            'It needs a PDS storage adapter, the shared contract tests, permission and error mapping, and a separate token broker that accepts only short-lived sign-in material for code exchange, refresh and revocation.',
          ),
        ),
      ],
    ),
    ConnectionHelpSection(
      title: syncText(context, '官方流程要点', 'Key points of the official flow'),
      items: [
        ConnectionHelpItem(
          title: syncText(
            context,
            '创建开发者版域和应用',
            'Create a developer-edition domain and app',
          ),
          body: syncText(
            context,
            '阿里云官方文档要求在网盘与相册服务（开发者版）的域列表中创建 WebServer 应用，并在应用列表中取得 client_id 和 client_secret。Secret 必须保密。',
            'Aliyun documentation has you create a WebServer app in the domain list of Drive and Photo Service (developer edition), then take the client_id and client_secret from the app list. The secret must stay confidential.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(
            context,
            '回调地址必须完全匹配',
            'The redirect address must match exactly',
          ),
          body: syncText(
            context,
            '授权请求和换 Token 请求都需要 redirect_uri，且必须与创建应用时配置的 OAuth2.0 回调 URL 一致。授权码只能使用一次，文档说明其有效期为 10 分钟。',
            'Both the authorize request and the token exchange need a redirect_uri, and it must match the OAuth 2.0 callback URL set when the app was created. The code works once and, per the documentation, is valid for 10 minutes.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, 'Token 生命周期', 'Token lifetime'),
          body: syncText(
            context,
            '官方 WebServer 文档示例中 access_token 默认有效期为 2 小时，refresh_token 有效期更长；刷新请求仍然需要 client_secret。',
            'In the official WebServer examples an access_token is valid for 2 hours by default and a refresh_token for longer; refreshing still requires the client_secret.',
          ),
        ),
        ConnectionHelpItem(
          title: syncText(context, '官方文档', 'Official documentation'),
          body: syncText(
            context,
            '阿里云 PDS OAuth WebServer 接入流程：https://help.aliyun.com/zh/pds/drive-and-photo-service-dev/user-guide/oauth-2-0-access-process-for-web-server-applications。',
            'Aliyun PDS OAuth WebServer access process: https://help.aliyun.com/zh/pds/drive-and-photo-service-dev/user-guide/oauth-2-0-access-process-for-web-server-applications.',
          ),
        ),
      ],
    ),
  ],
);
