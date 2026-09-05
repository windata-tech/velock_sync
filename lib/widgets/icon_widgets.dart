import 'package:flutter/material.dart';
import 'package:velock_sync/core/extensions.dart';

class ProtocolIcon extends StatelessWidget {
  final String protocolName;
  final Color? iconColor;

  const ProtocolIcon({super.key, required this.protocolName, this.iconColor});

  @override
  Widget build(BuildContext context) {
    final color = iconColor ?? context.primaryColor;
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        color: color.withValues(alpha: 0.12),
      ),
      alignment: Alignment.center,
      child: Text(
        protocolName,
        style: context.titleStyle?.copyWith(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
