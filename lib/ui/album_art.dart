import 'dart:typed_data';
import 'package:flutter/material.dart';

// Reusable widget to render album art consistently across the app
class AlbumArt extends StatelessWidget {
  const AlbumArt({
    super.key,
    required this.size,
    this.imageBytes,
    this.borderRadius = 8.0,
    this.borderWidth = 1.0,
    this.borderColor,
    this.placeholder,
    this.cacheWidth,
    this.cacheHeight,
    this.fit = BoxFit.cover,
    this.filterQuality,
    this.gaplessPlayback = true,
  });

  final Uint8List? imageBytes;
  final double size;
  final double borderRadius;
  final double borderWidth;
  final Color? borderColor;
  final Widget? placeholder;
  final int? cacheWidth;
  final int? cacheHeight;
  final BoxFit fit;
  final FilterQuality? filterQuality;
  // We pretty much always want gapless playback since we're reading from memory
  final bool gaplessPlayback;

  @override
  Widget build(BuildContext context) {
    final Color resolvedBorderColor =
        borderColor ?? Theme.of(context).colorScheme.outlineVariant;

    final Widget resolvedPlaceholder = Center(
      child: placeholder ?? Icon(Icons.music_note, size: size * 0.44),
    );

    final bool hasBytes = imageBytes != null && imageBytes!.isNotEmpty;

    final FilterQuality resolvedFilterQuality =
        filterQuality ?? FilterQuality.none;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        border: borderWidth > 0
            ? Border.all(color: resolvedBorderColor, width: borderWidth)
            : null,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: hasBytes
          ? ClipRRect(
              borderRadius: BorderRadius.circular(borderRadius),
              child: Image.memory(
                imageBytes!,
                width: size,
                height: size,
                cacheWidth: cacheWidth ?? size.ceil(),
                cacheHeight: cacheHeight ?? size.ceil(),
                fit: fit,
                filterQuality: resolvedFilterQuality,
                gaplessPlayback: gaplessPlayback,
                errorBuilder: (context, error, stackTrace) =>
                    resolvedPlaceholder,
              ),
            )
          : resolvedPlaceholder,
    );
  }
}
