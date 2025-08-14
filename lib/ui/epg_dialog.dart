// EPG Dialog, shows the Program Guide
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:orbit/app_state.dart';
import 'package:orbit/metadata/channel_data.dart';
import 'package:orbit/device_layer.dart';
import 'package:orbit/sxi_command_types.dart';
import 'package:orbit/sxi_commands.dart';
import 'package:orbit/sxi_layer.dart';
import 'package:orbit/ui/channel_info_dialog.dart';
import 'package:orbit/ui/album_art.dart';
import 'package:orbit/helpers.dart';
import 'package:orbit/ui/epg_search.dart';

class EpgDialog extends StatefulWidget {
  final AppState appState;
  final SXiLayer sxiLayer;
  final DeviceLayer deviceLayer;
  final int? initialCategory;
  final ScrollController mainScrollController;
  final ListController mainListController;
  final ScrollController categoryScrollController;
  final ListController categoryListController;

  const EpgDialog({
    super.key,
    required this.appState,
    required this.sxiLayer,
    required this.deviceLayer,
    this.initialCategory,
    required this.mainScrollController,
    required this.mainListController,
    required this.categoryScrollController,
    required this.categoryListController,
  });

  @override
  State<EpgDialog> createState() => _EpgDialogState();
}

class _EpgDialogState extends State<EpgDialog> {
  int? selectedCategory;
  String searchQuery = '';
  late List<ChannelData> _sortedChannels;
  final Map<int, Uint8List> _sidLogoCache = {};
  final Map<String, Uint8List> _trackArtCache = {};
  Timer? _debounce;
  bool _pendingScrollToTop = false;
  final TextEditingController _searchController = TextEditingController();
  @override
  void initState() {
    super.initState();
    selectedCategory = widget.initialCategory;
    _sortedChannels = widget.appState.sidMap.values.toList()
      ..sort((a, b) => a.channelNumber.compareTo(b.channelNumber));
    if (_sortedChannels.length > 2) {
      _sortedChannels = _sortedChannels.sublist(2);
    }

    // Set up initial scrolling after the widget is built
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setupInitialScrolling();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _setupInitialScrolling() {
    // Position category strip
    if (widget.initialCategory != null) {
      widget.categoryListController.jumpToItem(
        index: widget.initialCategory! + 1,
        scrollController: widget.categoryScrollController,
        alignment: 0.5,
      );
    }

    // Compute index within the displayed list (respects initialCategory)
    List<ChannelData> displayList = _sortedChannels;
    if (widget.initialCategory != null) {
      displayList =
          displayList.where((c) => c.catId == widget.initialCategory).toList();
    }
    final idx = displayList
        .indexWhere((c) => c.channelNumber == widget.appState.currentChannel);
    if (idx >= 0) {
      widget.mainListController.jumpToItem(
        index: idx,
        scrollController: widget.mainScrollController,
        alignment: 0.0, // Align to top
      );
    }
  }

  void _refreshDialog() {
    setState(() {
      _sortedChannels = widget.appState.sidMap.values.toList()
        ..sort((a, b) => a.channelNumber.compareTo(b.channelNumber));
      if (_sortedChannels.length > 2) {
        _sortedChannels = _sortedChannels.sublist(2);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setupInitialScrolling();
    });
  }

  @override
  Widget build(BuildContext context) {
    var currentPrograms = widget.appState.sidMap.values.toList();
    currentPrograms
        .sort((ch1, ch2) => ch1.channelNumber.compareTo(ch2.channelNumber));
    if (currentPrograms.length > 2) {
      currentPrograms = currentPrograms.sublist(2);
    }

    final List<ChannelData> baseList = _sortedChannels
        .where((channel) =>
            selectedCategory == null || channel.catId == selectedCategory)
        .toList();

    final trimmedQuery = searchQuery.trim();
    final lowerQuery = trimmedQuery.toLowerCase();
    final String categoryLabel = selectedCategory == null
        ? 'All Channels'
        : (widget.appState.categories[selectedCategory] ?? 'Category');

    List<ChannelData> filteredChannels;
    if (lowerQuery.isEmpty) {
      // No search, keep original ordering (by channel number)
      filteredChannels = baseList;
    } else {
      // Compute relevance score for each channel, sort by score
      final isNumeric = int.tryParse(lowerQuery) != null;
      final results = <_SearchResult>[];
      final List<String> qTokens = EpgSearchUtils.tokenizeQuery(lowerQuery);
      final Iterable<ChannelData> candidates = isNumeric
          ? baseList
          : baseList.where((c) => EpgSearchUtils.matchesAllTokens(c, qTokens));
      for (final channel in candidates) {
        final double score = EpgSearchUtils.computeSearchScore(
          channel,
          lowerQuery,
          isNumeric: isNumeric,
        );
        if (score > 0) {
          results.add(_SearchResult(channel: channel, score: score));
        }
      }
      results.sort((a, b) {
        final cmp = b.score.compareTo(a.score);
        if (cmp != 0) return cmp;
        // Tie-break by channel number
        return a.channel.channelNumber.compareTo(b.channel.channelNumber);
      });
      filteredChannels = results.map((r) => r.channel).toList();
    }

    // Wait for the list to be attached before scrolling to the top
    if (_pendingScrollToTop) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final bool listVisible =
            !(lowerQuery.isNotEmpty && filteredChannels.isEmpty);
        if (listVisible) {
          try {
            widget.mainListController.jumpToItem(
              index: 0,
              scrollController: widget.mainScrollController,
              alignment: 0.0,
            );
          } catch (_) {
            // If controller isn't attached yet, ignore
          }
        }
        if (mounted) {
          setState(() {
            _pendingScrollToTop = false;
          });
        }
      });
    }

    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Row with Refresh and Close buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Now Playing...'),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh',
                onPressed: _refreshDialog,
              ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Close',
                onPressed: () => Navigator.pop(context, -1),
              ),
            ],
          ),
          // Search field - always visible
          SizedBox(
            height: 50,
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search song/artist or channel...',
                prefixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            searchQuery = '';
                          });
                        },
                        icon: const Icon(Icons.clear),
                      )
                    : Icon(Icons.search),
              ),
              onChanged: (value) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 200), () {
                  if (!mounted) return;
                  setState(() {
                    searchQuery = value;
                  });
                });
              },
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 50,
            width: MediaQuery.of(context).size.width,
            child: SuperListView.builder(
              controller: widget.categoryScrollController,
              listController: widget.categoryListController,
              scrollDirection: Axis.horizontal,
              itemCount: widget.appState.categories.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4.0),
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        foregroundColor: selectedCategory == null
                            ? Colors.blue
                            : Colors.grey,
                      ),
                      onPressed: () {
                        setState(() {
                          selectedCategory = null;
                          _pendingScrollToTop = true;
                        });
                      },
                      child: const Text('All Channels'),
                    ),
                  );
                } else {
                  // Each category button; adjust index by subtracting 1
                  final entries = widget.appState.categories.entries.toList();
                  final entry = entries[index - 1];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4.0),
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        foregroundColor: selectedCategory == entry.key
                            ? Colors.blue
                            : Colors.grey,
                      ),
                      onPressed: () {
                        setState(() {
                          selectedCategory = entry.key;
                          _pendingScrollToTop = true;
                        });
                      },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            getCategoryIcon(entry.value),
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Text(entry.value),
                        ],
                      ),
                    ),
                  );
                }
              },
            ),
          )
        ],
      ),
      content: SizedBox(
        width: 400,
        height: 600,
        child: (lowerQuery.isNotEmpty && filteredChannels.isEmpty)
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      categoryLabel == 'All Channels'
                          ? 'No results'
                          : 'No results in "$categoryLabel"',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (selectedCategory != null) ...[
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: () {
                          setState(() {
                            selectedCategory = null;
                            _pendingScrollToTop = true;
                          });
                        },
                        child: const Text('Search All Channels'),
                      ),
                    ],
                  ],
                ),
              )
            : SuperListView.builder(
                controller: widget.mainScrollController,
                listController: widget.mainListController,
                // SuperListView doesn't support itemExtent; keep rows light-weight
                itemCount: filteredChannels.length,
                itemBuilder: (context, index) {
                  var program = filteredChannels[index];
                  final trackKey = '${program.sid}-${program.currentPid}';
                  final trackBytes = widget.appState.imageMap[program.sid]
                      ?[program.currentPid];
                  final trackArt = trackBytes == null
                      ? null
                      : (_trackArtCache[trackKey] ??=
                          Uint8List.fromList(trackBytes));
                  final logoList =
                      widget.appState.storageData.getImageForSid(program.sid);
                  final channelLogo = logoList.isEmpty
                      ? null
                      : (_sidLogoCache[program.sid] ??=
                          Uint8List.fromList(logoList));

                  return LayoutBuilder(
                    builder: (context, constraints) {
                      // Hide album art if width is less than 300px (for mobile)
                      final canDisplayFullWidth = constraints.maxWidth >= 300;
                      final bool isNowPlaying =
                          widget.appState.currentChannel ==
                              program.channelNumber;
                      final theme = Theme.of(context);

                      return Container(
                          decoration: BoxDecoration(
                            color: isNowPlaying
                                ? theme.colorScheme.primary
                                    .withValues(alpha: 0.05)
                                : Colors.transparent,
                            border: isNowPlaying
                                ? Border.all(
                                    color: theme.colorScheme.primary,
                                    width: 2,
                                  )
                                : null,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: ListTile(
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 16.0),
                            key: ValueKey<int>(program.sid),
                            selected: isNowPlaying,
                            leading: canDisplayFullWidth
                                ? AlbumArt(
                                    size: 50,
                                    cacheWidth: 64,
                                    cacheHeight: 64,
                                    imageBytes: trackArt,
                                    borderRadius: 4.0,
                                    borderWidth: 1.0,
                                    placeholder: Icon(
                                      getCategoryIcon(widget.appState
                                              .categories[program.catId] ??
                                          ''),
                                      size: 22,
                                    ),
                                  )
                                : null,
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text.rich(
                                    TextSpan(
                                      children:
                                          EpgSearchUtils.buildHighlightedSpans(
                                        context: context,
                                        text: program.currentSong,
                                        query: trimmedQuery,
                                      ),
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            subtitle: Text.rich(
                              TextSpan(
                                children: EpgSearchUtils.buildHighlightedSpans(
                                  context: context,
                                  text: program.currentArtist,
                                  query: trimmedQuery,
                                ),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: canDisplayFullWidth
                                ? Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Text(
                                              'Channel ${program.channelNumber}'),
                                          if (channelLogo == null)
                                            Text.rich(
                                              TextSpan(
                                                children: EpgSearchUtils
                                                    .buildHighlightedSpans(
                                                  context: context,
                                                  text: program.channelName,
                                                  query: trimmedQuery,
                                                  ignoredTokens: EpgSearchUtils
                                                      .channelNameStopwords,
                                                ),
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                              textAlign: TextAlign.end,
                                            )
                                          else
                                            Container(
                                              color: Colors.transparent,
                                              height: 30,
                                              width: 80,
                                              child: Image.memory(
                                                channelLogo,
                                                cacheHeight: 128,
                                                fit: BoxFit.fitHeight,
                                                gaplessPlayback: true,
                                                filterQuality:
                                                    FilterQuality.medium,
                                                errorBuilder: (_, __, ___) {
                                                  return Text(
                                                    program.channelName,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    textAlign: TextAlign.end,
                                                  );
                                                },
                                              ),
                                            ),
                                        ],
                                      ),
                                      Row(children: [
                                        IconButton(
                                            tooltip: 'View channel info',
                                            icon: Icon(Icons.info_outline),
                                            onPressed: () {
                                              ChannelInfoDialog.show(
                                                context,
                                                appState: widget.appState,
                                                sid: program.sid,
                                                deviceLayer: widget.deviceLayer,
                                                onTuneAlign: (channelNumber) {
                                                  // Align EPG to All Channels, jump to tuned channel
                                                  setState(() {
                                                    selectedCategory = null;
                                                  });
                                                  // Recompute the currently visible list (category + search)
                                                  WidgetsBinding.instance
                                                      .addPostFrameCallback(
                                                          (_) {
                                                    // Build base list
                                                    List<ChannelData> baseList =
                                                        widget.appState.sidMap
                                                            .values
                                                            .toList();
                                                    baseList.sort((a, b) => a
                                                        .channelNumber
                                                        .compareTo(
                                                            b.channelNumber));
                                                    if (baseList.length > 2) {
                                                      baseList =
                                                          baseList.sublist(2);
                                                    }
                                                    if (selectedCategory !=
                                                        null) {
                                                      baseList = baseList
                                                          .where((c) =>
                                                              c.catId ==
                                                              selectedCategory)
                                                          .toList();
                                                    }

                                                    // Apply search filter
                                                    final trimmed =
                                                        searchQuery.trim();
                                                    final lower =
                                                        trimmed.toLowerCase();
                                                    List<ChannelData>
                                                        visibleList;
                                                    if (lower.isEmpty) {
                                                      visibleList = baseList;
                                                    } else {
                                                      final isNumeric =
                                                          int.tryParse(lower) !=
                                                              null;
                                                      final results =
                                                          <_SearchResult>[];
                                                      final tokens =
                                                          EpgSearchUtils
                                                              .tokenizeQuery(
                                                                  lower);
                                                      final candidates = isNumeric
                                                          ? baseList
                                                          : baseList.where((c) =>
                                                              EpgSearchUtils
                                                                  .matchesAllTokens(
                                                                      c,
                                                                      tokens));
                                                      for (final ch
                                                          in candidates) {
                                                        final score = EpgSearchUtils
                                                            .computeSearchScore(
                                                          ch,
                                                          lower,
                                                          isNumeric: isNumeric,
                                                        );
                                                        if (score > 0) {
                                                          results.add(
                                                            _SearchResult(
                                                              channel: ch,
                                                              score: score,
                                                            ),
                                                          );
                                                        }
                                                      }
                                                      results.sort((a, b) {
                                                        final cmp = b.score
                                                            .compareTo(a.score);
                                                        if (cmp != 0) {
                                                          return cmp;
                                                        }
                                                        return a.channel
                                                            .channelNumber
                                                            .compareTo(b.channel
                                                                .channelNumber);
                                                      });
                                                      visibleList = results
                                                          .map((r) => r.channel)
                                                          .toList();
                                                    }

                                                    final idx = visibleList
                                                        .indexWhere((c) =>
                                                            c.channelNumber ==
                                                            channelNumber);
                                                    if (idx >= 0) {
                                                      try {
                                                        widget
                                                            .mainListController
                                                            .jumpToItem(
                                                          index: idx,
                                                          scrollController: widget
                                                              .mainScrollController,
                                                          alignment: 0.5,
                                                        );
                                                      } catch (_) {
                                                        // If controller isn't ready, ignore
                                                      }
                                                    }
                                                  });
                                                },
                                              );
                                            }),
                                      ]),
                                    ],
                                  )
                                : Container(
                                    color: Colors.transparent,
                                    height: 30,
                                    width: 50,
                                    child: channelLogo == null
                                        ? Text.rich(
                                            TextSpan(
                                              children: EpgSearchUtils
                                                  .buildHighlightedSpans(
                                                context: context,
                                                text: program.channelName,
                                                query: trimmedQuery,
                                                ignoredTokens: EpgSearchUtils
                                                    .channelNameStopwords,
                                              ),
                                            ),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.center,
                                          )
                                        : Image.memory(
                                            channelLogo,
                                            cacheHeight: 128,
                                            fit: BoxFit.contain,
                                            alignment: Alignment.centerRight,
                                            gaplessPlayback: true,
                                            filterQuality: FilterQuality.medium,
                                            errorBuilder: (_, __, ___) {
                                              return Text(
                                                program.channelName,
                                                overflow: TextOverflow.ellipsis,
                                                textAlign: TextAlign.end,
                                              );
                                            },
                                          ),
                                  ),
                            onTap: () {
                              Navigator.pop(context, index);
                              final cfgCmd = SXiSelectChannelCommand(
                                ChanSelectionType.tuneUsingChannelNumber,
                                program.channelNumber,
                                0xFF,
                                Overrides.all(),
                                AudioRoutingType.routeToAudio,
                              );
                              widget.deviceLayer.sendControlCommand(cfgCmd);
                            },
                          ));
                    },
                  );
                },
              ),
      ),
    );
  }
}

class _SearchResult {
  final ChannelData channel;
  final double score;
  _SearchResult({required this.channel, required this.score});
}

class EpgDialogHelper {
  static Future<int> showEpgDialog({
    required BuildContext context,
    required AppState appState,
    required SXiLayer sxiLayer,
    required DeviceLayer deviceLayer,
    int? initialCategory,
    required ScrollController mainScrollController,
    required ListController mainListController,
    required ScrollController categoryScrollController,
    required ListController categoryListController,
  }) async {
    return await showDialog<int>(
          barrierDismissible: true,
          context: context,
          builder: (BuildContext context) => EpgDialog(
            appState: appState,
            sxiLayer: sxiLayer,
            deviceLayer: deviceLayer,
            initialCategory: initialCategory,
            mainScrollController: mainScrollController,
            mainListController: mainListController,
            categoryScrollController: categoryScrollController,
            categoryListController: categoryListController,
          ),
        ) ??
        0;
  }
}
