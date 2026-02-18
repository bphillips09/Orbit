// Widget to display a channel logo image with outline in light mode
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

class ChannelLogoImage extends StatelessWidget {
  const ChannelLogoImage({
    super.key,
    required this.bytes,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.cacheWidth,
    this.cacheHeight,
    this.filterQuality = FilterQuality.medium,
    this.gaplessPlayback = true,
    this.alignment = Alignment.center,
    this.outlineDilateRadiusX = 0.5,
    this.outlineDilateRadiusY = 0.5,
    this.outlineAlpha = 1,
    this.fallbackBuilder,
  });

  final Uint8List? bytes;
  final double? width;
  final double? height;
  final BoxFit fit;
  final int? cacheWidth;
  final int? cacheHeight;
  final FilterQuality filterQuality;
  final bool gaplessPlayback;
  final AlignmentGeometry alignment;

  final double outlineDilateRadiusX;
  final double outlineDilateRadiusY;
  final double outlineAlpha;
  final WidgetBuilder? fallbackBuilder;

  @override
  Widget build(BuildContext context) {
    final data = bytes;
    if (data == null || data.isEmpty) {
      return fallbackBuilder?.call(context) ?? const SizedBox.shrink();
    }

    final isLight = Theme.of(context).brightness == Brightness.light;

    Widget buildLogo({
      Color? color,
      BlendMode? blendMode,
    }) {
      return Image.memory(
        data,
        width: width,
        height: height,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
        fit: fit,
        alignment: alignment,
        gaplessPlayback: gaplessPlayback,
        filterQuality: filterQuality,
        color: color,
        colorBlendMode: blendMode,
        errorBuilder: (context, error, stackTrace) {
          return fallbackBuilder?.call(context) ?? const SizedBox.shrink();
        },
      );
    }

    final fullColor = buildLogo();
    if (!isLight) return fullColor;

    final underlay = buildLogo(
      color: Colors.black.withValues(alpha: outlineAlpha),
      blendMode: BlendMode.srcIn,
    );

    final bool dilateOutline =
        outlineDilateRadiusX > 0.0 || outlineDilateRadiusY > 0.0;

    return Stack(
      alignment: Alignment.center,
      children: [
        dilateOutline
            ? ImageFiltered(
                imageFilter: ui.ImageFilter.dilate(
                  radiusX: outlineDilateRadiusX,
                  radiusY: outlineDilateRadiusY,
                ),
                child: underlay,
              )
            : underlay,
        fullColor,
      ],
    );
  }
}
