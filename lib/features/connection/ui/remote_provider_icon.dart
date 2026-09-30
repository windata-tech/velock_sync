import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';

/// One glyph and one colour per storage type, so the protocol picker and the
/// connection list tell services apart at a glance instead of showing several
/// near-identical clouds. The colours only hint at each service's brand; they
/// are not the official logos.
///
/// Where the owner publishes a logo for apps like this one, [RemoteProviderBadge]
/// shows it instead (see [remoteProviderOfficialLogo]).
IconData remoteProviderIcon(BuildContext context, RemoteProviderType type) =>
    switch (type) {
      RemoteProviderType.webDav => adaptiveIcon(
        context,
        material: Icons.dns_outlined,
        cupertino: CupertinoIcons.rectangle_stack,
      ),
      RemoteProviderType.googleDrive => adaptiveIcon(
        context,
        material: Icons.change_history,
        cupertino: CupertinoIcons.triangle_fill,
      ),
      RemoteProviderType.oneDrive => adaptiveIcon(
        context,
        material: Icons.cloud,
        cupertino: CupertinoIcons.cloud_fill,
      ),
      RemoteProviderType.baiduNetdisk => adaptiveIcon(
        context,
        material: Icons.inventory_2_outlined,
        cupertino: CupertinoIcons.archivebox_fill,
      ),
      RemoteProviderType.aliyunDrive => adaptiveIcon(
        context,
        material: Icons.view_in_ar,
        cupertino: CupertinoIcons.cube_box_fill,
      ),
    };

Color remoteProviderColor(RemoteProviderType type) => switch (type) {
  RemoteProviderType.webDav => const Color(0xFF5856D6),
  RemoteProviderType.googleDrive => const Color(0xFF0F9D58),
  RemoteProviderType.oneDrive => const Color(0xFF0078D4),
  RemoteProviderType.baiduNetdisk => const Color(0xFFE0343A),
  RemoteProviderType.aliyunDrive => const Color(0xFFFF6A00),
};

/// Official logos, only for owners whose brand rules allow a third-party app
/// to show them without a licence:
///
/// - Google Drive: developers.google.com/drive/branding — no pre-approval,
///   may be resized but not otherwise changed.
///
/// OneDrive is left out on purpose: Microsoft's trademark guidelines ask apps
/// without a licence not to use its logos. Baidu Netdisk and Aliyun Drive stay
/// on the drawn icon until their developer consoles confirm the rules. Every
/// logo added here needs an entry in NOTICE and in `registerTrademarkNotices`.
String? remoteProviderOfficialLogo(RemoteProviderType type) => switch (type) {
  RemoteProviderType.googleDrive => 'assets/providers/google_drive.png',
  _ => null,
};

class RemoteProviderBadge extends StatelessWidget {
  const RemoteProviderBadge(this.type, {super.key});

  final RemoteProviderType type;

  static const _size = 40.0;

  @override
  Widget build(BuildContext context) {
    final logo = remoteProviderOfficialLogo(type);
    if (logo == null) {
      return AdaptiveIconBadge(
        icon: remoteProviderIcon(context, type),
        color: remoteProviderColor(type),
      );
    }
    // Shown as published: no tinted tile, no recolouring, only resized.
    return SizedBox.square(
      dimension: _size,
      child: Center(
        child: Image.asset(
          logo,
          width: _size * 0.7,
          height: _size * 0.7,
          filterQuality: FilterQuality.medium,
          excludeFromSemantics: true,
        ),
      ),
    );
  }
}

/// Adds the trademark notices for [remoteProviderOfficialLogo] to the licence
/// page reached from Settings → About & open-source licenses.
void registerTrademarkNotices() {
  LicenseRegistry.addLicense(
    () => Stream.value(
      const LicenseEntryWithLineBreaks(
        ['Google Drive'],
        'Google Drive is a trademark of Google LLC. Use of this trademark is '
        'subject to Google Permissions. Velock Sync is not affiliated with '
        'or endorsed by Google.',
      ),
    ),
  );
}
