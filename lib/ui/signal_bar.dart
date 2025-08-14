import 'package:flutter/material.dart';

class SignalBar extends StatelessWidget {
  final int level;
  final int maxLevel;
  final double height;
  final double segmentSpacing;
  final bool isAntennaConnected;

  const SignalBar({
    super.key,
    required this.level,
    this.maxLevel = 4,
    this.height = 8.0,
    this.segmentSpacing = 2.0,
    this.isAntennaConnected = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final int segments = maxLevel + 1;
    final int clampedLevel = level.clamp(0, maxLevel).toInt();

    final Color fillColor = _getSignalColor(clampedLevel, theme);
    final Color emptyColor = theme.colorScheme.surfaceContainer;
    final Color borderColor = theme.colorScheme.outline.withValues(alpha: 0.3);

    List<Widget> children = [];
    for (int i = 0; i < segments; i++) {
      final bool filled = i < clampedLevel;
      children.add(
        Expanded(
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: filled ? fillColor : emptyColor,
              borderRadius: BorderRadius.circular(2),
              border: Border.all(color: borderColor, width: 1),
            ),
          ),
        ),
      );
      if (i != segments - 1) {
        children.add(SizedBox(width: segmentSpacing));
      }
    }

    return Semantics(
      label: 'Signal strength',
      value: '$clampedLevel of $maxLevel',
      child: Row(children: children),
    );
  }

  Color _getSignalColor(int signalQuality, ThemeData theme) {
    if (!isAntennaConnected || signalQuality <= 0) {
      return theme.colorScheme.error;
    }
    if (signalQuality >= 3) {
      return theme.colorScheme.primary;
    } else {
      return theme.colorScheme.tertiary;
    }
  }
}
