import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:velock_sync/core/extensions.dart';

class ProtocolIcon extends StatelessWidget {
  final String protocolName;
  final Color? iconColor;

  const ProtocolIcon({super.key, required this.protocolName, this.iconColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), color: iconColor ?? context.primaryColor),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(PlatformIcons(context).folderSolid, size: 24, color: Colors.white),
          Positioned(
            bottom: 7,
            child: Text(protocolName, style: context.titleStyle?.copyWith(color: context.primaryColor, fontSize: 8)),
          ),
        ],
      ),
    );
  }
}
