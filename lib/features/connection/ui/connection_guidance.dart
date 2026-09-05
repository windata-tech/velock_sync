import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';

/// Detailed, provider-specific setup documentation.
///
/// The form pages only link here. Keeping the long-form explanation separate
/// leaves the form focused on entering values while still making every setup
/// detail available when it is needed.
class ConnectionHelpPage extends StatelessWidget {
  const ConnectionHelpPage({super.key, this.providerType});

  final RemoteProviderType? providerType;

  @override
  Widget build(BuildContext context) {
    final documents = providerType == null
        ? const [
            _webDavDocument,
            _googleDriveDocument,
            _oneDriveDocument,
            _baiduNetdiskDocument,
            _aliyunDriveDocument,
          ]
        : [_documentFor(providerType!)];

    return AdaptiveScaffold(
      title: '连接说明',
      actions: providerType == RemoteProviderType.baiduNetdisk
          ? [
              PlatformTextButton(
                padding: EdgeInsets.zero,
                onPressed: () =>
                    context.pushNamed(AppRoutes.newBaiduToken.name),
                child: const Text('配置 Token'),
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
                ? '远端服务配置说明'
                : '${documents.single.title} 配置说明',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            providerType == null
                ? '这里说明每个远程服务需要提前准备什么、每个字段怎么填写、保存后会发生什么，以及遇到错误时从哪里开始排查。'
                : documents.single.intro,
            style: TextStyle(color: context.appSecondaryLabel, height: 1.45),
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

  static ConnectionHelpDocument _documentFor(RemoteProviderType provider) =>
      switch (provider) {
        RemoteProviderType.webDav => _webDavDocument,
        RemoteProviderType.googleDrive => _googleDriveDocument,
        RemoteProviderType.oneDrive => _oneDriveDocument,
        RemoteProviderType.baiduNetdisk => _baiduNetdiskDocument,
        RemoteProviderType.aliyunDrive => _aliyunDriveDocument,
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
            style: TextStyle(color: context.appSecondaryLabel, height: 1.45),
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
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: context.appSecondaryLabel,
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
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
    final titleStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700, height: 1.25);
    final numberStyle = titleStyle?.copyWith(
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
              style: TextStyle(color: context.appSecondaryLabel, height: 1.45),
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

const _webDavDocument = ConnectionHelpDocument(
  title: 'WebDAV',
  intro: 'WebDAV 适合连接 NAS、Nextcloud 或其他兼容服务。请先确认当前设备能访问服务器，再填写表单。',
  sections: [
    ConnectionHelpSection(
      title: '开始前准备',
      items: [
        ConnectionHelpItem(
          title: '确认服务端已开启 WebDAV',
          body: '服务端需要允许当前账号进行目录读取、创建目录、上传、下载和删除操作。只开启网页管理后台，不代表 WebDAV 已经可用。',
          bullets: [
            '确认 WebDAV 服务的实际访问地址和监听端口。',
            '确认账号对目标目录有读写权限，而不是只有只读权限。',
            '如果服务端按应用单独生成密码，请使用应用密码，不要填登录后台的其他凭据。',
          ],
        ),
        ConnectionHelpItem(
          title: '先确认网络可达',
          body: '在同一台设备上用浏览器或其他 WebDAV 客户端访问服务器，先排除 DNS、VPN、局域网隔离和防火墙问题。',
        ),
        ConnectionHelpItem(
          title: '优先使用 HTTPS',
          body:
              'HTTPS 会保护账号凭据和同步数据在传输过程中的机密性。只有在可信内网、且服务器确实无法提供 HTTPS 时，才考虑关闭 HTTPS。',
        ),
      ],
    ),
    ConnectionHelpSection(
      title: '字段怎么填',
      items: [
        ConnectionHelpItem(
          title: '启用 HTTPS',
          body:
              '开关必须和服务器地址的协议一致。开启时地址以 https:// 开头，通常端口为 443；关闭时地址以 http:// 开头，通常端口为 80。',
        ),
        ConnectionHelpItem(
          title: '服务器地址',
          body:
              '填写服务端的基础地址，例如 https://nas.example.com。地址必须包含协议和主机名；不要把用户名和密码写进 URL。',
          bullets: [
            '如果服务端给出的地址已经包含固定目录，可以按服务端文档原样填写。',
            '如果固定目录单独填写在“子路径”，两个字段不要重复写同一段路径。',
          ],
        ),
        ConnectionHelpItem(
          title: '端口',
          body: '填写服务器实际监听的数字端口。443 和 80 只是常见默认值，NAS 或反向代理使用自定义端口时，以服务端配置为准。',
        ),
        ConnectionHelpItem(
          title: '子路径',
          body:
              '填写 WebDAV 服务下用于保存同步对象的目录段，例如 /webdav 或 /remote/velock。留空表示从服务端基础目录开始。',
          bullets: [
            '不要填完整 URL，也不要再次填写 https:// 和主机名。',
            '如果服务端文档要求路径以 / 开头，请按文档填写；不要凭感觉改成文件系统路径。',
          ],
        ),
        ConnectionHelpItem(
          title: '用户名和密码',
          body:
              '服务器要求认证时，两项一起填写。匿名 WebDAV 才可以同时留空；填写密码但不填用户名，或反过来，通常会导致认证失败。编辑已有连接时，密码留空表示保留原密码。',
        ),
      ],
    ),
    ConnectionHelpSection(
      title: '保存时会发生什么',
      items: [
        ConnectionHelpItem(
          title: '先做表单校验',
          body: '应用会检查地址格式、协议前缀和必填端口。校验提示出现时，先修正字段，不会开始网络连接。',
        ),
        ConnectionHelpItem(
          title: '再测试实际连接',
          body:
              '点击保存后，应用会使用填写的地址、端口、路径和凭据访问远端目录，确认连接可以用于同步。测试失败时不会把一个未验证的连接留在列表里。',
        ),
        ConnectionHelpItem(
          title: '凭据单独保存',
          body: '密码只写入系统安全存储，连接配置本身不会包含明文密码。保存成功后，连接会回到“连接”页面。',
        ),
      ],
    ),
    ConnectionHelpSection(
      title: '失败时按这个顺序排查',
      items: [
        ConnectionHelpItem(
          title: '先看地址和协议',
          body: '确认 https/http 与开关一致，主机名没有拼写错误，地址没有多余空格，也没有把端口重复写进路径。',
        ),
        ConnectionHelpItem(
          title: '再看端口和路径',
          body:
              '用服务端提供的 WebDAV 地址验证端口；如果返回 404 或找不到目录，检查子路径是否是 WebDAV 根路径，而不是网页后台路径。',
        ),
        ConnectionHelpItem(
          title: '遇到 401 或 403',
          body: '这通常是账号、密码或目录权限问题。重新确认账号是否允许 WebDAV，是否需要应用专用密码，以及目标目录是否允许写入。',
        ),
        ConnectionHelpItem(
          title: '遇到证书错误或超时',
          body: '证书错误通常来自自签名证书、域名不匹配或证书过期；超时则优先检查 VPN、端口转发、防火墙和局域网隔离。',
        ),
        ConnectionHelpItem(
          title: '只读成功但保存失败',
          body: '说明读取权限存在，但创建目录、上传或删除权限不足。请给账号授予目标目录的完整 WebDAV 写权限，再重新测试。',
        ),
      ],
    ),
    ConnectionHelpSection(
      title: '安全注意事项',
      items: [
        ConnectionHelpItem(
          title: '不要在公共网络使用 HTTP',
          body:
              'HTTP 不会加密传输内容和 Basic Auth 凭据。公共 Wi-Fi、端口转发和不受信任的代理环境都不适合使用 HTTP。',
        ),
        ConnectionHelpItem(
          title: '不要把凭据放进截图或日志',
          body: '分享问题截图时遮住服务器地址中的私密信息、用户名和所有可能识别家庭网络的内容。密码不会显示在页面上。',
        ),
      ],
    ),
  ],
);

const _googleDriveDocument = ConnectionHelpDocument(
  title: 'Google Drive',
  intro:
      'Google Drive 使用系统浏览器完成 OAuth 授权。应用只保存授权引用，不在连接配置或日志中保存 Refresh Token。',
  sections: [
    ConnectionHelpSection(
      title: '开始前准备',
      items: [
        ConnectionHelpItem(
          title: '准备公开 OAuth Client ID',
          body:
              '在 Google Cloud 项目中启用 Drive API，配置 OAuth 同意屏幕并创建 OAuth Client ID。移动端使用公开客户端，不需要、也不应该把 Client Secret 放进应用。',
          bullets: [
            '将 Client ID 作为构建参数 GOOGLE_OAUTH_CLIENT_ID 传入。',
            '没有传入 Client ID 时，页面会显示“授权未就绪”，保存按钮不会开始授权。',
            '测试账号、组织策略或未发布的同意屏幕，可能限制哪些账号可以登录。',
          ],
        ),
        ConnectionHelpItem(
          title: '登记回调地址',
          body:
              '授权完成后，系统浏览器通过 velocksync://oauth/callback 把结果交回应用。Google Cloud 中登记的回调配置必须与构建版本使用的地址一致。',
        ),
        ConnectionHelpItem(
          title: '确认访问范围',
          body: '当前实现使用 drive.file 范围：应用可以访问它创建的文件，以及用户在授权流程中明确选择或授予应用访问权的文件。',
        ),
      ],
    ),
    ConnectionHelpSection(
      title: '页面字段怎么理解',
      items: [
        ConnectionHelpItem(
          title: '远端根目录 ID',
          body:
              '这是授权后浏览远端目录的起始位置。默认值 appDataFolder 指向 Google 为应用保留的隐藏安全空间，适合保存 Velock 的同步对象，不会把这些对象混在普通网盘文件中。',
        ),
        ConnectionHelpItem(
          title: '账号显示名称',
          body: '这是连接列表里显示给你的备注，不参与授权，也不会改变 Google 账号。留空时应用会使用授权账号或目录摘要。',
        ),
        ConnectionHelpItem(
          title: '不要把文件夹网页链接当成 ID',
          body:
              '如果要从普通 Drive 文件夹开始，使用授权后提供的目录选择器选择它。不要直接把浏览器地址栏中的整段 URL 粘贴进根目录 ID。',
        ),
      ],
    ),
    ConnectionHelpSection(
      title: '完整操作流程',
      items: [
        ConnectionHelpItem(
          title: '点击保存并完成登录',
          body:
              '应用会打开系统浏览器。选择正确的 Google 账号，查看权限请求并允许访问；不要在授权过程中关闭 Velock 或清理浏览器会话。',
        ),
        ConnectionHelpItem(
          title: '选择同步目录',
          body: '回到应用后会打开远端目录选择器。最终保存的目录以选择器中的选择为准。',
        ),
        ConnectionHelpItem(
          title: '等待连接检查完成',
          body: '应用会读取所选位置并检查是否可以作为同步目标。检查成功后，连接才会出现在“连接”页面。',
        ),
        ConnectionHelpItem(
          title: '以后重新授权',
          body: '如果授权过期、撤销或账号策略变化，在连接详情页使用“重新授权”。不需要重新创建同步配置。',
        ),
      ],
    ),
    ConnectionHelpSection(
      title: '常见问题',
      items: [
        ConnectionHelpItem(
          title: '提示授权未就绪',
          body:
              '检查构建命令是否包含 --dart-define=GOOGLE_OAUTH_CLIENT_ID=你的客户端 ID，并确认使用的是正确环境的构建产物。',
        ),
        ConnectionHelpItem(
          title: '登录后没有回到应用',
          body:
              '检查自定义回调地址是否登记正确，系统是否允许 velocksync 链接唤起应用；如果浏览器停在空白页，返回应用查看是否已经收到回调。',
        ),
        ConnectionHelpItem(
          title: '看不到目标文件夹',
          body: '当前授权范围只显示应用有权访问的文件。确认你登录的是正确账号，并先在 Google Drive 中打开或授权目标文件夹。',
        ),
        ConnectionHelpItem(
          title: '授权成功但连接检查失败',
          body:
              '检查 Drive API 是否启用、同意屏幕是否允许当前账号，以及网络是否能访问 Google API。若目录刚创建，稍等片刻后重新授权或重新测试。',
        ),
      ],
    ),
    ConnectionHelpSection(
      title: '隐私与安全',
      items: [
        ConnectionHelpItem(
          title: '令牌不会出现在连接配置里',
          body: 'Access Token 和 Refresh Token 由系统安全存储管理。连接页面只展示账号、目录和状态等非敏感信息。',
        ),
        ConnectionHelpItem(
          title: '撤销访问',
          body: '删除连接时应用会尝试撤销远端授权并清理本地凭据；如果网络暂时不可用，先不要反复删除重建，稍后重试更安全。',
        ),
      ],
    ),
  ],
);

const _oneDriveDocument = ConnectionHelpDocument(
  title: 'OneDrive',
  intro:
      'OneDrive 使用 Microsoft 的系统浏览器授权流程。应用通过 Microsoft Graph 访问你选择的目录，并把令牌留在系统安全存储中。',
  sections: [
    ConnectionHelpSection(
      title: '开始前准备',
      items: [
        ConnectionHelpItem(
          title: '创建公开客户端应用',
          body:
              '在 Microsoft Entra 管理中心注册应用，使用适合移动端的公开客户端配置。应用不接受 Client Secret，也不会把 Secret 编译进客户端。',
          bullets: [
            '将 Application (client) ID 作为构建参数 ONEDRIVE_OAUTH_CLIENT_ID 传入。',
            '根据组织策略选择允许的账号类型；个人账号和工作/学校账号的可用范围可能不同。',
            '如果租户要求管理员同意 Files.ReadWrite 或 offline_access，需要先完成管理员同意。',
          ],
        ),
        ConnectionHelpItem(
          title: '登记回调地址',
          body:
              '授权完成后，系统浏览器通过 velocksync://oauth/callback 回到应用。Entra 应用注册中的移动端回调配置必须与这个地址一致。',
        ),
        ConnectionHelpItem(
          title: '确认 Graph 权限',
          body:
              '当前实现请求 Files.ReadWrite 和 offline_access，用于读写同步对象并在下次使用时刷新访问令牌。组织管理员可能需要批准这些权限。',
        ),
      ],
    ),
    ConnectionHelpSection(
      title: '页面字段怎么理解',
      items: [
        ConnectionHelpItem(
          title: '远端根目录 ID',
          body:
              '这是目录选择器开始浏览的位置。默认 root 表示当前账号的 OneDrive 根目录；你也可以填入一个已知目录 ID，让选择器从该位置开始。最终保存的目录以授权后的选择为准。',
        ),
        ConnectionHelpItem(
          title: '账号显示名称',
          body: '这是连接列表中的可读备注，只用于区分多个 OneDrive 连接。留空不会影响授权或同步。',
        ),
        ConnectionHelpItem(
          title: '根目录和同步目录不是一回事',
          body:
              'root 只是浏览起点，不代表应用一定把数据写在 OneDrive 根目录。完成授权后，请在目录选择器中确认真正要用于同步的位置。',
        ),
      ],
    ),
    ConnectionHelpSection(
      title: '完整操作流程',
      items: [
        ConnectionHelpItem(
          title: '点击保存并登录',
          body: '应用会打开系统浏览器。使用正确的 Microsoft 账号登录，确认租户和权限后同意访问。不要在授权途中关闭应用。',
        ),
        ConnectionHelpItem(
          title: '选择同步目录',
          body: '回到应用后进入 OneDrive 目录选择器。可以进入子目录，也可以返回上一级；选择完成后，当前目录会成为同步目标。',
        ),
        ConnectionHelpItem(
          title: '等待连接检查完成',
          body: '应用会读取所选目录并验证 Graph 访问权限。检查成功后才会保存连接并回到“连接”页面。',
        ),
        ConnectionHelpItem(
          title: '以后重新授权',
          body: '当管理员策略改变、令牌失效或账号撤销授权时，在连接详情页使用“重新授权”，不需要重新填写同步配置。',
        ),
      ],
    ),
    ConnectionHelpSection(
      title: '常见问题',
      items: [
        ConnectionHelpItem(
          title: '提示授权未就绪',
          body:
              '检查构建命令是否包含 --dart-define=ONEDRIVE_OAUTH_CLIENT_ID=你的 Application (client) ID，并确认没有把 Directory (tenant) ID 填错。',
        ),
        ConnectionHelpItem(
          title: '提示重定向地址不匹配',
          body:
              '重新检查 Entra 应用注册的平台类型和回调地址。地址必须使用 velocksync://oauth/callback，协议、主机和路径都不能改。',
        ),
        ConnectionHelpItem(
          title: '目录列表为空或无法打开',
          body:
              '确认登录账号对该目录有访问权，并确认组织的条件访问策略没有阻止移动端公共客户端。必要时让管理员重新授予 Files.ReadWrite 同意。',
        ),
        ConnectionHelpItem(
          title: '授权成功但连接检查失败',
          body:
              '检查 Microsoft Graph 服务状态、账号租户策略和网络；如果目录刚刚创建或权限刚刚变更，等待几秒后重新授权通常比连续点击保存更有效。',
        ),
      ],
    ),
    ConnectionHelpSection(
      title: '隐私与安全',
      items: [
        ConnectionHelpItem(
          title: '令牌由系统安全存储保管',
          body:
              'Access Token 和 Refresh Token 不会显示在界面、连接 JSON 或普通日志中。同步只使用当前账号获得的授权范围。',
        ),
        ConnectionHelpItem(
          title: '组织策略优先',
          body: '工作或学校账号可能受到租户管理员、条件访问和数据位置策略限制。应用无法绕过这些策略，需要在 Entra 管理端完成配置。',
        ),
      ],
    ),
  ],
);

const _baiduNetdiskDocument = ConnectionHelpDocument(
  title: '百度网盘',
  intro:
      '百度网盘的 OAuth 文档提供授权码、简化和设备码三种模式。当前页面可以把你已经取得的 AppKey、Token 和可选 SecretKey 保存到系统安全存储，但这不等于已经创建了可同步连接。',
  sections: [
    ConnectionHelpSection(
      title: '先说清楚当前状态',
      items: [
        ConnectionHelpItem(
          title: '“配置 Token”能做什么',
          body:
              '它会把百度 OAuth 凭据保存到当前设备的系统安全存储中，避免凭据进入普通偏好设置、连接 JSON、同步包或诊断日志。再次打开页面时，已保存的字段会回填到表单中。',
        ),
        ConnectionHelpItem(
          title: '为什么之前显示“暂不可用”',
          body:
              '这不是说百度网盘账号不能授权，而是当前仓库还没有百度网盘 RemoteObjectStore 适配器，连接状态检查和实际上传/下载还没有实现。同时，百度官方设备码、授权码和刷新 Token 的请求都要求 SecretKey；把这个密钥编译进移动端并不安全。',
        ),
        ConnectionHelpItem(
          title: '保存后为什么不会出现在连接列表',
          body:
              '凭据配置页只保存 Token，不创建一个无法执行同步的假连接。等百度适配器和受信任的 Token Broker 完成后，才会把这组凭据接入真正的连接向导。',
        ),
        ConnectionHelpItem(
          title: '什么时候才算真正支持',
          body:
              '至少需要百度网盘 RemoteObjectStore、统一对象存储契约测试、401/403/429 等错误映射，以及不把 SecretKey 暴露给移动端的授权或 Token Broker 流程。',
        ),
      ],
    ),
    ConnectionHelpSection(
      title: '在百度官方平台准备应用',
      items: [
        ConnectionHelpItem(
          title: '进入百度网盘开放平台控制台',
          body:
              '官方控制台入口：https://pan.baidu.com/union/console/applist?from=doc_header。登录百度账号后，在应用列表中创建或选择应用。',
        ),
        ConnectionHelpItem(
          title: '记录 AppKey 和 SecretKey',
          body:
              'AppKey 是应用标识，SecretKey 是应用密钥。AppKey 可以作为客户端标识使用；SecretKey 属于机密信息，不要提交到代码仓库、截图、构建参数、崩溃日志或聊天记录。',
        ),
        ConnectionHelpItem(
          title: '申请网盘权限',
          body:
              '百度官方示例使用 scope=basic,netdisk。实际 Token 返回的 scope 还会受到应用配置和用户同意结果影响；页面中的 Scope 至少要包含 netdisk，否则不能代表网盘访问授权。',
        ),
        ConnectionHelpItem(
          title: '需要回调地址时按控制台原值填写',
          body:
              '授权码模式要求 redirect_uri 与百度控制台设置完全一致。百度文档还允许无 Server 应用使用 redirect_uri=oob；不要把 Velock 的 velocksync:// 回调地址直接填给百度，除非百度控制台和当前授权流程都明确支持并登记了它。',
        ),
      ],
    ),
    ConnectionHelpSection(
      title: '官方三种授权方式怎么选',
      items: [
        ConnectionHelpItem(
          title: '授权码模式：适合有服务端的正式接入',
          body:
              '先访问 authorize 接口取得 code，再由服务端调用 token 接口换取 access_token、expires_in 和 refresh_token。code 只能使用一次，10 分钟未使用会过期；换 Token 时需要 AppKey、SecretKey 和完全匹配的 redirect_uri。',
          bullets: [
            '官方授权入口示例：https://openapi.baidu.com/oauth/2.0/authorize?response_type=code&client_id=AppKey&redirect_uri=回调地址&scope=basic,netdisk。',
            '如果 code 已经使用过或已过期，不要重复提交，重新发起授权。',
          ],
        ),
        ConnectionHelpItem(
          title: '简化模式：只有短期 Access Token',
          body:
              '把 response_type 设为 token，授权后直接从回调结果中取得 access_token 和 expires_in。百度 FAQ 明确说明，这种模式有效期较短且不支持刷新，过期后必须重新登录授权。',
          bullets: [
            '适合临时验证，不适合长期无人值守同步。',
            '如果你只有这一类 Token，页面可以只填写 AppKey 和 Access Token，SecretKey、Refresh Token 与过期时间可以留空。',
          ],
        ),
        ConnectionHelpItem(
          title: '设备码模式：适合无回调或输入受限的设备',
          body:
              '先用 AppKey 请求 device_code、user_code、verification_url 和 qrcode_url，让用户在浏览器或手机完成授权；再用 device_code 轮询 token 接口。官方示例返回 expires_in=300 秒、interval=5 秒，轮询间隔不要低于 5 秒。',
          bullets: [
            '换 Token 的 grant_type 是 device_token，并且官方文档要求提交 SecretKey。',
            '成功后通常会得到有效期 30 天的 access_token 和可刷新的 refresh_token。',
            'refresh_token 只能使用一次；刷新响应返回的新 refresh_token 必须替换旧值。',
          ],
        ),
      ],
    ),
    ConnectionHelpSection(
      title: 'Token 配置页每个字段怎么填',
      items: [
        ConnectionHelpItem(
          title: 'AppKey',
          body:
              '必填。填写百度控制台中应用的 AppKey，不要填应用名称、AppID 或整段授权 URL。它用于标识是哪一个百度应用获得了授权。',
        ),
        ConnectionHelpItem(
          title: 'SecretKey',
          body:
              '当前为可选字段。简化模式只需要已有 Access Token 时可以留空；设备码换 Token、授权码换 Token 或刷新 Token 时，百度官方流程需要它。输入后只保存在系统安全存储中，但移动端仍不能把它当作真正不可提取的机密。',
        ),
        ConnectionHelpItem(
          title: 'Access Token',
          body:
              '必填。只粘贴 Token 值本身，不要带 Bearer 前缀、引号、换行或参数名 access_token=。它代表用户授予应用的当前访问凭证。',
        ),
        ConnectionHelpItem(
          title: 'Refresh Token',
          body:
              '可选。授权码或设备码模式通常会返回它；简化模式不支持刷新。百度的 refresh_token 是一次性轮换值，每次刷新成功后必须把新值覆盖旧值，否则下次刷新会失败。',
        ),
        ConnectionHelpItem(
          title: 'Access Token 过期时间',
          body:
              '可选，使用 ISO 8601 时间，例如 2026-08-07T12:00:00Z。官方返回 expires_in 时可以根据当前时间换算；不知道准确时间时留空，不要凭感觉填一个很远的日期。',
        ),
        ConnectionHelpItem(
          title: 'Scope',
          body:
              '默认填写 basic,netdisk。可以用逗号或空格分隔，但必须包含 netdisk。页面中的 Scope 只是记录 Token 的授权范围，不会替你向百度申请新的权限。',
        ),
      ],
    ),
    ConnectionHelpSection(
      title: '保存和排错',
      items: [
        ConnectionHelpItem(
          title: '保存按钮做什么',
          body:
              '保存按钮只校验必填字段、Scope 和可选的日期格式，然后把凭据写入系统安全存储。它不会调用百度 API，也不会创建连接或开始同步。',
        ),
        ConnectionHelpItem(
          title: 'redirect_uri_mismatch',
          body:
              '百度返回这个错误时，通常是授权请求里的 redirect_uri 与控制台安全设置不完全一致。逐字符检查协议、域名、端口、路径、大小写和尾部斜杠；如果是 oob 流程，确保使用的是官方允许的 oob 值。',
        ),
        ConnectionHelpItem(
          title: 'invalid_client 或 SecretKey 错误',
          body:
              '确认 AppKey 和 SecretKey 属于同一个应用，且没有把 AppID、应用名称或复制时带入的空格当成 SecretKey。不要为了排错把 SecretKey 写入日志。',
        ),
        ConnectionHelpItem(
          title: 'code 或 device_code 失效',
          body:
              '授权码只能用一次并在 10 分钟后过期；device_code 默认只在返回的 expires_in 内有效。重新发起授权，不要重复轮询已经过期的 code。',
        ),
        ConnectionHelpItem(
          title: 'refresh_token 刷新失败',
          body:
              '先确认没有并发刷新同一值。百度要求 refresh_token 一次性使用，成功响应中的新 refresh_token 要替换旧值；如果刷新请求失败，官方建议重新发起授权，而不是循环重试旧值。',
        ),
      ],
    ),
    ConnectionHelpSection(
      title: '安全边界',
      items: [
        ConnectionHelpItem(
          title: 'Token 等同于用户网盘操作凭据',
          body:
              '百度 FAQ 明确不推荐把 access_token 分发给多个客户端，因为泄露后他人可以操作用户网盘内容。不要把 Token 粘贴到工单、群聊、截图、同步包或公开仓库。',
        ),
        ConnectionHelpItem(
          title: 'SecretKey 不适合放进公共移动应用',
          body:
              '只要 SecretKey 在移动端运行时可用，就不能保证永远不被提取。个人测试可以在你信任的设备上临时配置；正式多人使用应通过独立、最小权限的 Token Broker 完成授权和刷新。',
        ),
        ConnectionHelpItem(
          title: '官方文档入口',
          body:
              '百度网盘开放平台文档：https://pan.baidu.com/union/doc/；授权介绍：https://pan.baidu.com/union/doc/使用入门/接入授权/授权介绍/；设备码模式：https://pan.baidu.com/union/doc/使用入门/接入授权/设备码模式授权/；接入 access_token FAQ：https://pan.baidu.com/union/doc/faq/接入access_token/。',
        ),
      ],
    ),
  ],
);

const _aliyunDriveDocument = ConnectionHelpDocument(
  title: '阿里云盘',
  intro:
      '阿里云盘当前没有在应用中开放连接或 Token 配置入口。官方 PDS 文档描述的是 WebServer OAuth 应用，涉及应用 ID、Secret、域和回调地址，不能安全地直接塞进移动客户端。',
  sections: [
    ConnectionHelpSection(
      title: '当前状态',
      items: [
        ConnectionHelpItem(
          title: '为什么没有 Token 输入框',
          body:
              '项目当前没有阿里云盘 RemoteObjectStore，也没有经过审核的 Token Broker。直接让移动端保存 App Secret 并宣称可以同步，会绕过官方应用安全边界，因此暂不开放配置。',
        ),
        ConnectionHelpItem(
          title: '正式开放前需要什么',
          body:
              '需要完成 PDS 对象存储适配器、统一契约测试、权限和错误映射，并通过只接收短期授权材料的独立 Token Broker 处理授权码、刷新和撤销。',
        ),
      ],
    ),
    ConnectionHelpSection(
      title: '官方流程要点',
      items: [
        ConnectionHelpItem(
          title: '创建开发者版域和应用',
          body:
              '阿里云官方文档要求在网盘与相册服务（开发者版）的域列表中创建 WebServer 应用，并在应用列表中取得 client_id 和 client_secret。Secret 必须保密。',
        ),
        ConnectionHelpItem(
          title: '回调地址必须完全匹配',
          body:
              '授权请求和换 Token 请求都需要 redirect_uri，且必须与创建应用时配置的 OAuth2.0 回调 URL 一致。授权码只能使用一次，文档说明其有效期为 10 分钟。',
        ),
        ConnectionHelpItem(
          title: 'Token 生命周期',
          body:
              '官方 WebServer 文档示例中 access_token 默认有效期为 2 小时，refresh_token 有效期更长；刷新请求仍然需要 client_secret。',
        ),
        ConnectionHelpItem(
          title: '官方文档',
          body:
              '阿里云 PDS OAuth WebServer 接入流程：https://help.aliyun.com/zh/pds/drive-and-photo-service-dev/user-guide/oauth-2-0-access-process-for-web-server-applications。',
        ),
      ],
    ),
  ],
);
