import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:velock_sync/appearance/design_tokens.dart';

/// First-run introduction shared by the selected-folder entry points.
class SelectedFolderEmptyState extends StatelessWidget {
  const SelectedFolderEmptyState({
    super.key,
    required this.onCreate,
    required this.onRecover,
  });

  final VoidCallback? onCreate;
  final VoidCallback? onRecover;

  @override
  Widget build(BuildContext context) {
    final primary = context.appPrimary;
    final label = Theme.of(context).colorScheme.onSurface;
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: (constraints.maxHeight - 56).clamp(0, double.infinity),
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ExcludeSemantics(
                      child: SizedBox(
                        height: 148,
                        child: Center(
                          child: SizedBox(
                            width: 172,
                            height: 144,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Container(
                                  width: 140,
                                  height: 140,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: primary.withValues(alpha: 0.06),
                                  ),
                                ),
                                Transform.rotate(
                                  angle: -0.09,
                                  child: Container(
                                    width: 104,
                                    height: 104,
                                    decoration: BoxDecoration(
                                      color: context.appGroupedSurface,
                                      borderRadius: BorderRadius.circular(28),
                                      boxShadow: [
                                        BoxShadow(
                                          color: primary.withValues(
                                            alpha: 0.09,
                                          ),
                                          blurRadius: 24,
                                          offset: const Offset(0, 10),
                                        ),
                                      ],
                                    ),
                                    child: Icon(
                                      CupertinoIcons.folder_fill,
                                      size: 60,
                                      color: primary,
                                    ),
                                  ),
                                ),
                                Positioned(
                                  right: 13,
                                  bottom: 10,
                                  child: Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: primary,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: context.appPageBackground,
                                        width: 4,
                                      ),
                                    ),
                                    child: const Icon(
                                      CupertinoIcons.arrow_2_circlepath,
                                      size: 23,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),
                    Text(
                      '让文件夹保持同步',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 25,
                        height: 1.3,
                        fontWeight: FontWeight.w700,
                        color: label,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '连接远端存储，选择本机文件夹，\n开始你的第一次同步。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.6,
                        color: context.appSecondaryLabel,
                      ),
                    ),
                    const SizedBox(height: 30),
                    CupertinoButton(
                      key: const Key('selected-folder-empty-create'),
                      color: primary,
                      borderRadius: BorderRadius.circular(14),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 16,
                      ),
                      onPressed: onCreate,
                      child: const Text(
                        '添加同步文件夹',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    CupertinoButton(
                      key: const Key('selected-folder-empty-recover'),
                      padding: const EdgeInsets.all(18),
                      color: context.appGroupedSurface,
                      borderRadius: BorderRadius.circular(16),
                      onPressed: onRecover,
                      child: Row(
                        children: [
                          Icon(
                            CupertinoIcons.arrow_down_doc,
                            color: primary,
                            size: 26,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '已有同步空间？',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: label,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  '通过恢复包加入',
                                  style: TextStyle(
                                    fontSize: 13,
                                    height: 1.4,
                                    color: context.appSecondaryLabel,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            CupertinoIcons.chevron_right,
                            size: 14,
                            color: context.appSecondaryLabel,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
