import 'dart:ui' as ui;

/// Heuristic for whether to offer [AppState.smallScreenMode] on first run (before Welcome).
///
/// Uses the primary [FlutterView]'s logical size (physical pixels / [devicePixelRatio]),
/// which matches Flutter's **dp** on Android. Tuned for phones and typical automotive
/// head units (e.g. 800×480, 1024×600, 1280×720).
bool inferCompactDisplayForSmallScreenMode() {
  final ui.FlutterView? view = ui.PlatformDispatcher.instance.implicitView;
  if (view == null) return false;

  final double dpr = view.devicePixelRatio;
  if (dpr <= 0) return false;

  final ui.Size physical = view.physicalSize;
  if (physical.width <= 0 || physical.height <= 0) return false;

  final double logicalW = physical.width / dpr;
  final double logicalH = physical.height / dpr;
  final double shortest = logicalW < logicalH ? logicalW : logicalH;
  final double longest = logicalW > logicalH ? logicalW : logicalH;

  // Phones and very small tablets / HUs (short edge ~600 dp or below).
  if (shortest <= 600) return true;

  // Common automotive and 720p-class panels (e.g. 1280×720, wide 1024×600).
  if (shortest <= 720 && longest <= 1480) return true;

  return false;
}
