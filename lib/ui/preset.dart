// Preset, represents a preset in the preset carousel
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:carousel_slider/carousel_slider.dart';
import 'package:orbit/app_state.dart';
import 'package:orbit/helpers.dart';
import 'package:orbit/ui/channel_logo_image.dart';
import 'package:provider/provider.dart';

class Preset {
  int sid;
  int channelNumber;
  String channelName;
  String song;
  String artist;

  Preset({
    this.sid = 0,
    this.channelNumber = 0,
    this.channelName = '',
    this.song = '',
    this.artist = '',
  });

  void setFromPlaybackInfo(PlaybackInfo playbackInfo) {
    sid = playbackInfo.sid;
    channelNumber = playbackInfo.channelNumber;
    channelName = playbackInfo.channelName;
    song = playbackInfo.songTitle;
    artist = playbackInfo.artistTitle;
  }

  @override
  String toString() {
    return 'Preset(sid: $sid, channelName: $channelName, channelNumber: $channelNumber)\n';
  }
}

int? computeNextPresetSid(AppState appState, {required bool left}) {
  int nextPresetIndex = 0;
  if (appState.presetCycleIndex != -1) {
    nextPresetIndex = appState.presetCycleIndex;
  }
  if (left) {
    nextPresetIndex--;
  } else {
    nextPresetIndex++;
  }
  if (nextPresetIndex < 0) {
    nextPresetIndex = appState.presets.length - 1;
  } else if (nextPresetIndex >= appState.presets.length) {
    nextPresetIndex = 0;
  }
  return appState.presets[nextPresetIndex].sid;
}

class PresetCarousel extends StatefulWidget {
  final List<Preset> presets;
  final int itemsPerPage;
  final Function(int sid) onPresetTap;
  final Function(int presetIndex) onPresetLongPress;
  final int? currentSid;
  final Uint8List? Function(int sid)? logoProvider;
  final String Function(int sid)? categoryNameProvider;

  const PresetCarousel({
    super.key,
    required this.presets,
    required this.onPresetTap,
    required this.onPresetLongPress,
    this.currentSid,
    this.itemsPerPage = 6,
    this.logoProvider,
    this.categoryNameProvider,
  });

  @override
  PresetCarouselState createState() => PresetCarouselState();
}

class PresetCarouselState extends State<PresetCarousel> {
  int _currentPage = 0;
  late CarouselSliderController _carouselController;
  static const double _navigationButtonWidth = 60.0;
  final Map<int, Uint8List> _logoCache = {};

  @override
  void initState() {
    super.initState();
    _carouselController = CarouselSliderController();
    _navigateToActivePreset();
  }

  @override
  void didUpdateWidget(PresetCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Navigate to active preset when the SID changes
    if (oldWidget.currentSid != widget.currentSid) {
      _navigateToActivePreset();
    }
  }

  void _navigateToActivePreset() {
    if (widget.currentSid == null) return;

    // Find the preset that matches the current SID
    final activePresetIndex = widget.presets.indexWhere(
      (preset) => preset.sid == widget.currentSid && preset.sid != 0,
    );

    if (activePresetIndex != -1) {
      final targetPage = activePresetIndex ~/ widget.itemsPerPage;

      // Navigate to the page that contains the active preset after carousel is ready
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && targetPage != _currentPage) {
          _carouselController.animateToPage(
            targetPage,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        }
      });
    }
  }

  void navigateToPreset(int sid) {
    if (widget.currentSid == null) return;

    final presetIndex = widget.presets.indexWhere(
      (preset) => preset.sid == sid,
    );

    if (presetIndex != -1) {
      final targetPage = presetIndex ~/ widget.itemsPerPage;

      // Navigate to the page that contains the preset after carousel is ready
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && targetPage != _currentPage) {
          _carouselController.animateToPage(
            targetPage,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        }
      });
    }
  }

  BoxDecoration _getPresetDecoration(ThemeData theme, Preset preset) {
    final bool isActive = widget.currentSid != null &&
        preset.sid == widget.currentSid &&
        preset.sid != 0;

    if (isActive) {
      // Active preset
      return BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        border: Border.all(
          color: theme.colorScheme.primary,
          width: 2,
        ),
        borderRadius: BorderRadius.circular(12.0),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.primary.withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      );
    } else {
      // Normal preset styling
      return BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.3),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(12.0),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isLandscapeMode = isLandscape(context);
    final appState = Provider.of<AppState>(context);

    // Calculate the number of pages needed
    final int totalPages = (widget.presets.length / widget.itemsPerPage).ceil();
    final int maxPages = max(1, totalPages);

    const double presetWindowHeight = 140;
    final theme = Theme.of(context);

    return SizedBox(
      height: presetWindowHeight,
      child: Column(
        mainAxisSize: MainAxisSize.max,
        children: [
          Expanded(
            child: Padding(
              padding: !isLandscapeMode
                  ? const EdgeInsets.only(left: 5, right: 5)
                  : EdgeInsets.zero,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Calculate item dimensions based on available space
                  final double availableWidth = constraints.maxWidth;
                  final double availableHeight = constraints.maxHeight;

                  final int itemsPerRow = isLandscapeMode ? 6 : 3;
                  final int rowsPerPage = isLandscapeMode ? 1 : 2;
                  final bool smallScreenMode = appState.smallScreenMode;

                  final double tileHeightForComparison = max(
                    0.0,
                    (availableHeight - (rowsPerPage - 1) * 4) / rowsPerPage,
                  );
                  final double navigationPaddingIfVisible =
                      maxPages > 1 && isLandscapeMode
                          ? _navigationButtonWidth * 2
                          : 0.0;
                  final double itemWidthWithNavigation = max(
                    0.0,
                    ((max(0.0, availableWidth - navigationPaddingIfVisible)) -
                            (itemsPerRow - 1) * 4) /
                        itemsPerRow,
                  );
                  final bool hideSideButtonsForTallTiles = smallScreenMode &&
                      isLandscapeMode &&
                      tileHeightForComparison > itemWidthWithNavigation;
                  final bool showSideNavigation = maxPages > 1 &&
                      isLandscapeMode &&
                      !hideSideButtonsForTallTiles;
                  final double navigationPadding =
                      showSideNavigation ? _navigationButtonWidth * 2 : 0.0;
                  final double effectiveWidth =
                      max(0.0, availableWidth - navigationPadding);
                  final double effectiveHeight = max(0.0, availableHeight);

                  // Clamp to avoid negative tight constraints
                  final double itemWidth = max(
                    0.0,
                    (effectiveWidth - (itemsPerRow - 1) * 4) / itemsPerRow,
                  );
                  final double itemHeight = max(
                    0.0,
                    (effectiveHeight - (rowsPerPage - 1) * 4) / rowsPerPage,
                  );

                  return Stack(
                    children: [
                      CarouselSlider.builder(
                        carouselController: _carouselController,
                        itemCount: maxPages,
                        itemBuilder: (context, pageIndex, realIndex) {
                          final int startIndex =
                              pageIndex * widget.itemsPerPage;
                          final int endIndex = min(
                              startIndex + widget.itemsPerPage,
                              widget.presets.length);
                          final List<Preset> pagePresets =
                              widget.presets.sublist(startIndex, endIndex);

                          return Container(
                            width: double.infinity,
                            height: double.infinity,
                            color: Colors.transparent,
                            padding: EdgeInsets.symmetric(
                                horizontal: showSideNavigation
                                    ? _navigationButtonWidth
                                    : 0.0),
                            alignment: Alignment.center,
                            child: Wrap(
                              spacing: 4,
                              runSpacing: 4,
                              alignment: WrapAlignment.center,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: () {
                                // Precompute per-preset logo bytes
                                final List<Uint8List?> pageLogoList =
                                    List<Uint8List?>.filled(
                                  pagePresets.length,
                                  null,
                                  growable: false,
                                );
                                for (int i = 0; i < pagePresets.length; i++) {
                                  final Preset p = pagePresets[i];
                                  if (p.sid == 0) {
                                    pageLogoList[i] = null;
                                    continue;
                                  }
                                  Uint8List? logoBytes;
                                  if (widget.logoProvider != null) {
                                    logoBytes = _logoCache[p.sid];
                                    if (logoBytes == null) {
                                      final Uint8List? fetched =
                                          widget.logoProvider!(p.sid);
                                      if (fetched != null) {
                                        _logoCache[p.sid] = fetched;
                                        logoBytes = fetched;
                                      }
                                    }
                                  }
                                  pageLogoList[i] = logoBytes;
                                }

                                return pagePresets.asMap().entries.map((entry) {
                                  final int idx = entry.key;
                                  final Preset preset = entry.value;
                                  final Uint8List? logoBytes =
                                      pageLogoList[idx];
                                  final int globalIndex = startIndex + idx;

                                  return Stack(
                                    children: [
                                      SizedBox(
                                        width: itemWidth,
                                        height: itemHeight,
                                        child: Material(
                                          color: Colors.transparent,
                                          child: Ink(
                                            decoration: _getPresetDecoration(
                                                theme, preset),
                                            child: InkWell(
                                              borderRadius:
                                                  BorderRadius.circular(12.0),
                                              onLongPress: () {
                                                widget.onPresetLongPress(
                                                    globalIndex);
                                              },
                                              onTap: () {
                                                if (preset.sid != 0) {
                                                  widget
                                                      .onPresetTap(preset.sid);
                                                }
                                              },
                                              child: Center(
                                                child: getPresetDisplay(
                                                  preset,
                                                  12.0,
                                                  logoBytes,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      // Preset index badge
                                      Positioned(
                                        top: 5,
                                        right: 5,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: widget.currentSid != null &&
                                                    preset.sid ==
                                                        widget.currentSid &&
                                                    preset.sid != 0
                                                ? theme.colorScheme
                                                    .surfaceContainer
                                                : theme.colorScheme
                                                    .primaryContainer,
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            border: Border.all(
                                              color: theme.colorScheme.outline
                                                  .withValues(alpha: 0.2),
                                              width: 0.5,
                                            ),
                                          ),
                                          child: Text(
                                            '${globalIndex + 1}',
                                            style: TextStyle(
                                              color: theme.colorScheme
                                                  .onPrimaryContainer,
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                            ),
                                            textAlign: TextAlign.center,
                                          ),
                                        ),
                                      ),
                                    ],
                                  );
                                }).toList();
                              }(),
                            ),
                          );
                        },
                        options: CarouselOptions(
                          height: availableHeight,
                          viewportFraction: 1.0,
                          enableInfiniteScroll: maxPages > 1,
                          onPageChanged: (index, reason) {
                            setState(() {
                              _currentPage = index;
                            });
                          },
                        ),
                      ),
                      // Navigation buttons
                      if (showSideNavigation) ...[
                        // Left button
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          child: GestureDetector(
                            onTap: () {
                              if (_currentPage > 0) {
                                _carouselController.previousPage(
                                  duration: const Duration(milliseconds: 300),
                                  curve: Curves.easeInOut,
                                );
                              } else {
                                // Endless scroll, go to last page
                                _carouselController.animateToPage(
                                  maxPages - 1,
                                  duration: const Duration(milliseconds: 300),
                                  curve: Curves.easeInOut,
                                );
                              }
                            },
                            child: Container(
                              width: _navigationButtonWidth,
                              color: Colors.transparent,
                              child: Center(
                                child: Icon(
                                  Icons.chevron_left,
                                  color: theme.colorScheme.onSurfaceVariant,
                                  size: 26,
                                ),
                              ),
                            ),
                          ),
                        ),
                        // Right button
                        Positioned(
                          right: 0,
                          top: 0,
                          bottom: 0,
                          child: GestureDetector(
                            onTap: () {
                              if (_currentPage < maxPages - 1) {
                                _carouselController.nextPage(
                                  duration: const Duration(milliseconds: 300),
                                  curve: Curves.easeInOut,
                                );
                              } else {
                                // Endless scroll, go to first page
                                _carouselController.animateToPage(
                                  0,
                                  duration: const Duration(milliseconds: 300),
                                  curve: Curves.easeInOut,
                                );
                              }
                            },
                            child: Container(
                              width: _navigationButtonWidth,
                              color: Colors.transparent,
                              child: Center(
                                child: Icon(
                                  Icons.chevron_right,
                                  color: theme.colorScheme.onSurfaceVariant,
                                  size: 26,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
          // Pagination dots
          Container(
            height: 20,
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(maxPages, (index) {
                return Container(
                  width: 8.0,
                  height: 8.0,
                  margin: const EdgeInsets.symmetric(horizontal: 4.0),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _currentPage == index
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline.withValues(alpha: 0.5),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget getPresetDisplay(
      Preset preset, double fontSize, Uint8List? logoBytes) {
    final theme = Theme.of(context);
    final appState = Provider.of<AppState>(context);

    if (preset.sid == 0) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.add_circle_outline,
              size: fontSize + 8, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 6),
          Text(
            'Hold to Add Preset',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: fontSize,
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      );
    } else {
      final bool isLoading = preset.channelNumber == 0;
      final bool hasLogo = !isLoading && logoBytes != null;
      final bool isLandscapeMode = isLandscape(context);
      final double lineHeight = isLandscapeMode ? 24 : 20;
      final double graphicHeightOffset = 1.4 / appState.textScale;
      final double graphicAreaHeight = lineHeight * graphicHeightOffset;
      final bool smallScreenMode = appState.smallScreenMode;

      // Small screen mode
      if (smallScreenMode) {
        if (isLandscapeMode) {
          final double logoHeight = 44;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
            child: Center(
              child: hasLogo
                  ? ChannelLogoImage(
                      bytes: logoBytes,
                      cacheHeight: 120,
                      height: logoHeight,
                      fit: BoxFit.fitWidth,
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.medium,
                    )
                  : Text(
                      isLoading ? 'Loading...' : preset.channelName,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: fontSize + 2,
                        color: theme.colorScheme.onSurface,
                      ),
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
          );
        }

        // Portrait: channel number only
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                isLoading ? '...' : '${preset.channelNumber}',
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w800,
                  color: theme.colorScheme.onSurface,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        );
      }

      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 8.0,
          vertical: isLandscapeMode ? 8.0 : 2.0,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Channel number (always in the same spot when available)
            if (!isLoading && preset.channelNumber != 0)
              Text(
                'Ch. ${preset.channelNumber}',
                style: TextStyle(
                  fontSize: fontSize - 1,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            SizedBox(height: isLandscapeMode ? 4 : 1),

            // Graphic/name area (fixed height, occupies two lines)
            SizedBox(
              height: graphicAreaHeight,
              child: Center(
                child: hasLogo
                    ? ChannelLogoImage(
                        bytes: logoBytes,
                        cacheHeight: 100,
                        height: graphicAreaHeight,
                        fit: BoxFit.fitWidth,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.medium,
                      )
                    : Center(
                        child: Text(
                          isLoading ? 'Loading...' : preset.channelName,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: fontSize * graphicHeightOffset,
                            color: theme.colorScheme.onSurface,
                          ),
                          maxLines: 1,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.clip,
                        ),
                      ),
              ),
            ),

            // Bottom metadata
            if (!isLoading) ...[
              SizedBox(height: isLandscapeMode ? 2 : 1),
              if (isLandscapeMode) ...[
                Text(
                  preset.song,
                  style: TextStyle(
                    fontSize: fontSize - 1,
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  preset.artist,
                  style: TextStyle(
                    fontSize: fontSize - 2,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ] else ...[
                Text(
                  '${preset.song} - ${preset.artist}',
                  style: TextStyle(
                    fontSize: fontSize - 1,
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ],
        ),
      );
    }
  }
}
