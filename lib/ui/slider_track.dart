// Slider Track, handles the transport slider
import 'package:flutter/material.dart';
import 'package:orbit/app_state.dart';

class TrackSnapInfo {
  final int trackIndex;
  final double snapPosition;
  final PlaybackInfo trackInfo;

  TrackSnapInfo({
    required this.trackIndex,
    required this.snapPosition,
    required this.trackInfo,
  });
}

class TrackSnappingHelper {
  static const double snapThreshold = 0.02; // 2% of slider width

  static List<double> calculateTrackPositions(
      List<PlaybackInfo> playbackInfo, int totalBufferTime) {
    if (totalBufferTime == 0) return [];

    List<double> positions = [];
    int cumulativeDuration = 0;

    for (final track in playbackInfo) {
      cumulativeDuration += track.duration;
      if (cumulativeDuration <= totalBufferTime) {
        positions.add(cumulativeDuration / totalBufferTime);
      }
    }

    return positions;
  }

  // Find the closest candidate for a given slider value
  static TrackSnapInfo? findSnapCandidate(
    double sliderValue,
    List<PlaybackInfo> playbackInfo,
    int totalBufferTime,
  ) {
    if (playbackInfo.isEmpty || totalBufferTime == 0) return null;

    List<double> trackPositions =
        calculateTrackPositions(playbackInfo, totalBufferTime);

    for (int i = 0; i < trackPositions.length && i < playbackInfo.length; i++) {
      double trackPosition = trackPositions[i];
      if ((sliderValue - trackPosition).abs() <= snapThreshold) {
        return TrackSnapInfo(
          trackIndex: i,
          snapPosition: trackPosition,
          trackInfo: playbackInfo[i],
        );
      }
    }

    return null;
  }

  // Find the track at a given position
  static TrackSnapInfo? findTrackAtPosition(
    double sliderValue,
    List<PlaybackInfo> playbackInfo,
    int totalBufferTime,
  ) {
    if (playbackInfo.isEmpty || totalBufferTime == 0) return null;

    int cumulativeDuration = 0;
    int targetTime = (sliderValue * totalBufferTime).round();

    for (int i = 0; i < playbackInfo.length; i++) {
      int trackStart = cumulativeDuration;
      cumulativeDuration += playbackInfo[i].duration;

      if (targetTime >= trackStart && targetTime < cumulativeDuration) {
        return TrackSnapInfo(
          trackIndex: i,
          snapPosition: sliderValue, // Use current position, not snap position
          trackInfo: playbackInfo[i],
        );
      }
    }

    return null;
  }

  // Apply snapping to a given value
  static double applySnapping(
    double originalValue,
    List<PlaybackInfo> playbackInfo,
    int totalBufferTime,
  ) {
    TrackSnapInfo? snapInfo =
        findSnapCandidate(originalValue, playbackInfo, totalBufferTime);
    return snapInfo?.snapPosition ?? originalValue;
  }
}

// Showing track info popup during snapping
class TrackInfoPopup extends StatelessWidget {
  final TrackSnapInfo snapInfo;
  final Offset position;

  const TrackInfoPopup({
    super.key,
    required this.snapInfo,
    required this.position,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: position.dx,
      top: -50, // Position just above the slider
      child: FractionalTranslation(
        translation: const Offset(-0.5, 0),
        child: Material(
          elevation: 8.0,
          borderRadius: BorderRadius.circular(8.0),
          color: Colors.black.withValues(alpha: 0.9),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
            constraints: const BoxConstraints(maxWidth: 200),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Row with album art on left and text info on right
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Show album art if available
                    if (snapInfo.trackInfo.image.isNotEmpty) ...[
                      Container(
                        margin: const EdgeInsets.only(right: 8.0),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4.0),
                          child: Image.memory(
                            cacheHeight: 40,
                            cacheWidth: 40,
                            snapInfo.trackInfo.image,
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.medium,
                            errorBuilder: (context, error, stackTrace) {
                              return const SizedBox
                                  .shrink(); // Hide if image fails to load
                            },
                          ),
                        ),
                      ),
                    ] else ...[
                      Container(
                        margin: const EdgeInsets.only(right: 8.0),
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white54),
                          borderRadius: BorderRadius.circular(4.0),
                        ),
                        child: const Icon(
                          Icons.music_note,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ],
                    // Text information column
                    Flexible(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Song title
                          Text(
                            snapInfo.trackInfo.songTitle.isNotEmpty
                                ? snapInfo.trackInfo.songTitle
                                : 'Track ${snapInfo.trackIndex + 1}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          // Artist name
                          Text(
                            snapInfo.trackInfo.artistTitle.isNotEmpty
                                ? snapInfo.trackInfo.artistTitle
                                : 'Unknown Artist',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 10,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                // Small triangle pointing down
                const SizedBox(height: 4.0),
                CustomPaint(
                  size: const Size(10, 5),
                  painter: TrianglePainter(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Custom painter for the triangle pointer
class TrianglePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final path = Path();
    path.moveTo(size.width / 2, size.height);
    path.lineTo(0, 0);
    path.lineTo(size.width, 0);
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class TrackMarkerSliderTrackShape extends SliderTrackShape {
  final List<PlaybackInfo> playbackInfo;
  final int totalBufferTime;

  TrackMarkerSliderTrackShape({
    required this.playbackInfo,
    required this.totalBufferTime,
  });

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    // Determine track height and thumb width
    final double trackHeight = sliderTheme.trackHeight ?? 4.0;
    final double thumbWidth =
        sliderTheme.thumbShape?.getPreferredSize(isEnabled, isDiscrete).width ??
            0;
    final double trackLeft = offset.dx + thumbWidth / 2;
    final double trackWidth = parentBox.size.width - thumbWidth;
    final double trackTop =
        offset.dy + (parentBox.size.height - trackHeight) / 2;
    return Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required Animation<double> enableAnimation,
    bool isDiscrete = false,
    bool isEnabled = false,
    required RenderBox parentBox,
    Offset? secondaryOffset,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required Offset thumbCenter,
  }) {
    final canvas = context.canvas;
    // Get the rectangle for the track
    final Rect trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );

    // Draw the basic track
    final Paint trackPaint = Paint()
      ..color = sliderTheme.activeTrackColor ?? Colors.blue;
    canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, Radius.circular(2.0)),
      trackPaint,
    );

    // Draw marker dots at each track boundary
    final Paint markerPaint = Paint()..color = Colors.deepPurple;
    int cumulativeDuration = 0;
    for (final track in playbackInfo) {
      cumulativeDuration += track.duration;
      // Avoid drawing a marker at the very end
      if (cumulativeDuration < totalBufferTime) {
        double fraction = cumulativeDuration / totalBufferTime;
        double markerX = trackRect.left + fraction * trackRect.width;
        // Draw a dot as the marker
        canvas.drawCircle(Offset(markerX, thumbCenter.dy), 3, markerPaint);
      }
    }
  }
}
