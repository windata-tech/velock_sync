import 'package:flutter/cupertino.dart';
import 'package:velock_sync/appearance/design_tokens.dart';

/// One selectable option whose explanation is shown in full.
///
/// The shared list tiles clamp a subtitle to a single line on iOS, which turned
/// the direction and conflict explanations into an ellipsis. These rows wrap the
/// whole sentence instead, because the deletion and conflict semantics are the
/// part the user must actually read before choosing.
class PlainOptionRow extends StatelessWidget {
  const PlainOptionRow({
    super.key,
    this.widgetKey,
    required this.selected,
    required this.title,
    required this.explanation,
    this.onTap,
    this.enabled = true,
  });

  final Key? widgetKey;
  final bool selected;
  final String title;
  final String explanation;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final accent = selected ? context.appPrimary : context.appSecondaryLabel;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: GestureDetector(
        key: widgetKey,
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.rowHorizontal,
            vertical: AppSpacing.rowVertical,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  selected
                      ? CupertinoIcons.checkmark_alt_circle_fill
                      : CupertinoIcons.circle,
                  size: 22,
                  color: accent,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppType.rowTitle),
                    const SizedBox(height: 2),
                    Text(
                      explanation,
                      style: AppType.rowSubtitle.copyWith(
                        color: context.appSecondaryLabel,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
