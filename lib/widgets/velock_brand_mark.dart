import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

/// The Velock brand mark, taken from the Velock app itself.
///
/// The coloured asset is the shield with its white "V" knocked out, so it sits
/// correctly on the light badge behind it. The flat asset is the same
/// silhouette in a single colour, which the bottom tab tints with its own
/// selected/unselected colours.
class VelockBrandMark extends StatelessWidget {
  const VelockBrandMark({
    super.key,
    this.size = 28,
    this.flat = false,
    this.color,
  });

  final double size;
  final bool flat;
  final Color? color;

  static const coloredAsset = 'assets/branding/velock_mark.png';
  static const flatAsset = 'assets/branding/velock_mark_flat.png';

  @override
  Widget build(BuildContext context) => Image.asset(
    flat ? flatAsset : coloredAsset,
    width: size,
    height: size,
    filterQuality: FilterQuality.high,
    color: flat ? color : null,
    colorBlendMode: flat ? BlendMode.srcIn : null,
    // A brand mark carries meaning through its shape only.
    excludeFromSemantics: true,
  );
}
