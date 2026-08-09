// EPG Dialog, shows the Program Guide
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:orbit/app_state.dart';
import 'package:orbit/metadata/channel_data.dart';
import 'package:orbit/device_layer.dart';
import 'package:orbit/sxi_command_types.dart';
import 'package:orbit/sxi_commands.dart';
import 'package:orbit/sxi_layer.dart';
import 'package:orbit/ui/channel_info_dialog.dart';
import 'package:orbit/helpers.dart';
import 'package:orbit/ui/epg_search.dart';
import 'package:orbit/ui/channel_list_entry.dart';
import 'package:orbit/ui/media_key_dialog_navigation.dart';
import 'package:orbit/ui/favorites_on_air_list.dart';
import 'package:orbit/ui/favorites_manager.dart';

class EpgDialog extends StatefulWidget {
  final AppState appState;
  final SXiLayer sxiLayer;
  final DeviceLayer deviceLayer;
  final int? initialCategory;
  final bool initialFavoritesOnAir;
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
    this.initialFavoritesOnAir = false,
    required this.mainScrollController,
    required this.mainListController,
    required this.categoryScrollController,
    required this.categoryListController,
  });

  @override
  State<EpgDialog> createState() => _EpgDialogState();
}

class _EpgDialogState extends State<EpgDialog> {
  static const int _favoritesStripIndex = 0;
  static const int _allChannelsStripIndex = 1;

  int? selectedCategory;
  bool _favoritesOnAirSelected = false;
  String searchQuery = '';
  late List<ChannelData> _sortedChannels;
  final Map<int, Uint8List> _sidLogoCache = {};
  final Map<String, Uint8List> _trackArtCache = {};
  Timer? _debounce;
  bool _pendingScrollToTop = false;
  int? _mediaKeyBindingToken;
  final TextEditingController _searchController = TextEditingController();
  late final FocusNode _searchFocusNode;

  @override
  void initState() {
    super.initState();
    _searchFocusNode = FocusNode(
      skipTraversal: true,
      debugLabel: 'epg-search',
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowDown ||
            key == LogicalKeyboardKey.arrowUp) {
          _searchFocusNode.unfocus();
          Actions.invoke(
            context,
            DirectionalFocusIntent(
              key == LogicalKeyboardKey.arrowDown
                  ? TraversalDirection.down
                  : TraversalDirection.up,
            ),
          );
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
    );
    if (widget.initialFavoritesOnAir) {
      _favoritesOnAirSelected = true;
      selectedCategory = null;
    } else {
      _favoritesOnAirSelected = false;
      selectedCategory = widget.initialCategory;
    }
    _sortedChannels = widget.appState.sidMap.values.toList()
      ..sort((a, b) => a.channelNumber.compareTo(b.channelNumber));
    if (_sortedChannels.length > 2) {
      _sortedChannels = _sortedChannels.sublist(2);
    }

    // Set up initial scrolling after the widget is built
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setupInitialScrolling();
      _registerMediaKeyNavigation();
    });
  }

  @override
  void dispose() {
    if (_mediaKeyBindingToken != null) {
      DialogMediaKeyNavigation.unregister(_mediaKeyBindingToken!);
      _mediaKeyBindingToken = null;
    }
    _changeFocusHighlightStrategy(FocusHighlightStrategy.automatic);
    _searchFocusNode.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _selectFavoritesOnAir() {
    setState(() {
      _favoritesOnAirSelected = true;
      selectedCategory = null;
      _pendingScrollToTop = true;
    });
  }

  void _selectAllChannels() {
    setState(() {
      _favoritesOnAirSelected = false;
      selectedCategory = null;
      _pendingScrollToTop = true;
    });
  }

  void _selectCategory(int catId) {
    setState(() {
      _favoritesOnAirSelected = false;
      selectedCategory = catId;
      _pendingScrollToTop = true;
    });
  }

  void _setupInitialScrolling() {
    // Position category strip
    if (_favoritesOnAirSelected) {
      try {
        widget.categoryListController.jumpToItem(
          index: _favoritesStripIndex,
          scrollController: widget.categoryScrollController,
          alignment: 0.0,
        );
      } catch (_) {}
      return;
    }

    if (widget.initialCategory != null) {
      // Favorites and All Channels precede categories
      widget.categoryListController.jumpToItem(
        index: widget.initialCategory! + 2,
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

  void _registerMediaKeyNavigation() {
    if (!widget.appState.mediaKeysNavigateFavoritesAndGuide) return;
    _mediaKeyBindingToken = DialogMediaKeyNavigation.register(
      onTrackNavigate: _handleTrackNavigate,
      onSelect: _handleSelect,
    );
  }

  void _changeFocusHighlightStrategy(FocusHighlightStrategy strategy) {
    FocusManager.instance.highlightStrategy = strategy;
  }

  List<ChannelData> _buildFilteredChannels() {
    final List<ChannelData> baseList = _sortedChannels
        .where((channel) =>
            selectedCategory == null || channel.catId == selectedCategory)
        .toList();

    final String trimmedQuery = searchQuery.trim();
    final String lowerQuery = trimmedQuery.toLowerCase();
    if (lowerQuery.isEmpty) {
      return baseList;
    }

    final bool isNumeric = int.tryParse(lowerQuery) != null;
    final List<_SearchResult> results = <_SearchResult>[];
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
      final int cmp = b.score.compareTo(a.score);
      if (cmp != 0) return cmp;
      return a.channel.channelNumber.compareTo(b.channel.channelNumber);
    });
    return results.map((r) => r.channel).toList();
  }

  Future<bool> _handleTrackNavigate(bool forward) async {
    if (!mounted) return false;
    _changeFocusHighlightStrategy(FocusHighlightStrategy.alwaysTraditional);
    if (_searchFocusNode.hasFocus) {
      _searchFocusNode.unfocus();
    }
    final BuildContext actionContext =
        FocusManager.instance.primaryFocus?.context ?? context;
    Actions.invoke(
      actionContext,
      DirectionalFocusIntent(
        forward ? TraversalDirection.down : TraversalDirection.up,
      ),
    );
    return true;
  }

  Future<bool> _handleSelect() async {
    if (!mounted) return false;
    _changeFocusHighlightStrategy(FocusHighlightStrategy.alwaysTraditional);
    final BuildContext actionContext =
        FocusManager.instance.primaryFocus?.context ?? context;
    Actions.invoke(actionContext, const ActivateIntent());
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final trimmedQuery = searchQuery.trim();
    final lowerQuery = trimmedQuery.toLowerCase();
    final String categoryLabel = _favoritesOnAirSelected
        ? 'Favorites'
        : selectedCategory == null
            ? 'All Channels'
            : (widget.appState.categories[selectedCategory] ?? 'Category');

    final List<ChannelData> filteredChannels = _favoritesOnAirSelected
        ? const <ChannelData>[]
        : _buildFilteredChannels();

    // Wait for the list to be attached before scrolling to the top
    if (_pendingScrollToTop && !_favoritesOnAirSelected) {
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
    } else if (_pendingScrollToTop && _favoritesOnAirSelected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
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
            children: [
              const Expanded(
                child: Text(
                  'Now Playing...',
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                ),
              ),
              if (_favoritesOnAirSelected)
                IconButton(
                  icon: const Icon(Icons.edit),
                  tooltip: 'Edit Favorites',
                  onPressed: () async {
                    await FavoritesManagerDialogHelper.show(
                      context: context,
                      appState: widget.appState,
                      deviceLayer: widget.deviceLayer,
                    );
                  },
                ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Close',
                onPressed: () => Navigator.pop(context, -1),
              ),
            ],
          ),
          SizedBox(
            height: 50,
            width: MediaQuery.sizeOf(context).width,
            child: SuperListView.builder(
              controller: widget.categoryScrollController,
              listController: widget.categoryListController,
              scrollDirection: Axis.horizontal,
              itemCount: widget.appState.categories.length + 2,
              itemBuilder: (context, index) {
                if (index == _favoritesStripIndex) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4.0),
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        foregroundColor:
                            _favoritesOnAirSelected ? Colors.blue : Colors.grey,
                      ),
                      onPressed: _selectFavoritesOnAir,
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.favorite, size: 16),
                          SizedBox(width: 6),
                          Text('Favorites'),
                        ],
                      ),
                    ),
                  );
                }
                if (index == _allChannelsStripIndex) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4.0),
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        foregroundColor:
                            !_favoritesOnAirSelected && selectedCategory == null
                                ? Colors.blue
                                : Colors.grey,
                      ),
                      onPressed: _selectAllChannels,
                      child: const Text('All Channels'),
                    ),
                  );
                }

                final entries = widget.appState.categories.entries.toList();
                final entry = entries[index - 2];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4.0),
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      foregroundColor: !_favoritesOnAirSelected &&
                              selectedCategory == entry.key
                          ? Colors.blue
                          : Colors.grey,
                    ),
                    onPressed: () => _selectCategory(entry.key),
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
              },
            ),
          ),
          if (!_favoritesOnAirSelected) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 50,
              child: TextField(
                focusNode: _searchFocusNode,
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
                      : const Icon(Icons.search),
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
          ],
        ],
      ),
      content: SizedBox(
        width: MediaQuery.sizeOf(context).width,
        height: 600,
        child: _favoritesOnAirSelected
            ? FavoritesOnAirList(
                appState: widget.appState,
                deviceLayer: widget.deviceLayer,
                onAfterTune: () {
                  if (mounted) Navigator.pop(context, -1);
                },
              )
            : (lowerQuery.isNotEmpty && filteredChannels.isEmpty)
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
                            onPressed: _selectAllChannels,
                            child: const Text('Search All Channels'),
                          ),
                        ],
                      ],
                    ),
                  )
                : SuperListView.builder(
                    controller: widget.mainScrollController,
                    listController: widget.mainListController,
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
                      final logoList = widget.appState.storageData
                          .getImageForSid(program.sid);
                      final channelLogo = logoList.isEmpty
                          ? null
                          : (_sidLogoCache[program.sid] ??=
                              Uint8List.fromList(logoList));

                      final bool isNowPlaying =
                          widget.appState.currentChannel ==
                              program.channelNumber;

                      return ChannelListEntry(
                        key: ValueKey<int>(program.sid),
                        isNowPlaying: isNowPlaying,
                        albumArt: trackArt,
                        placeholder: Icon(
                          getCategoryIcon(
                              widget.appState.categories[program.catId] ?? ''),
                          size: 22,
                        ),
                        titleSpans: EpgSearchUtils.buildHighlightedSpans(
                          context: context,
                          text: program.currentSong,
                          query: trimmedQuery,
                        ),
                        subtitleSpans: EpgSearchUtils.buildHighlightedSpans(
                          context: context,
                          text: program.currentArtist,
                          query: trimmedQuery,
                        ),
                        channelNumber: program.channelNumber,
                        channelLogo: channelLogo,
                        channelNameSpans: EpgSearchUtils.buildHighlightedSpans(
                          context: context,
                          text: program.channelName,
                          query: trimmedQuery,
                          ignoredTokens: EpgSearchUtils.channelNameStopwords,
                        ),
                        infoButton: IconButton(
                          tooltip: 'View channel info',
                          icon: const Icon(Icons.info_outline),
                          onPressed: () {
                            ChannelInfoDialog.show(
                              context,
                              appState: widget.appState,
                              sid: program.sid,
                              deviceLayer: widget.deviceLayer,
                              onTuneAlign: (channelNumber) {
                                _selectAllChannels();
                                WidgetsBinding.instance
                                    .addPostFrameCallback((_) {
                                  List<ChannelData> baseList =
                                      widget.appState.sidMap.values.toList();
                                  baseList.sort((a, b) => a.channelNumber
                                      .compareTo(b.channelNumber));
                                  if (baseList.length > 2) {
                                    baseList = baseList.sublist(2);
                                  }
                                  final trimmed = searchQuery.trim();
                                  final lower = trimmed.toLowerCase();
                                  List<ChannelData> visibleList;
                                  if (lower.isEmpty) {
                                    visibleList = baseList;
                                  } else {
                                    final isNumeric =
                                        int.tryParse(lower) != null;
                                    final results = <_SearchResult>[];
                                    final tokens =
                                        EpgSearchUtils.tokenizeQuery(lower);
                                    final candidates = isNumeric
                                        ? baseList
                                        : baseList.where((c) =>
                                            EpgSearchUtils.matchesAllTokens(
                                                c, tokens));
                                    for (final ch in candidates) {
                                      final score =
                                          EpgSearchUtils.computeSearchScore(
                                        ch,
                                        lower,
                                        isNumeric: isNumeric,
                                      );
                                      if (score > 0) {
                                        results.add(_SearchResult(
                                            channel: ch, score: score));
                                      }
                                    }
                                    results.sort((a, b) {
                                      final cmp = b.score.compareTo(a.score);
                                      if (cmp != 0) return cmp;
                                      return a.channel.channelNumber
                                          .compareTo(b.channel.channelNumber);
                                    });
                                    visibleList =
                                        results.map((r) => r.channel).toList();
                                  }
                                  final idx = visibleList.indexWhere(
                                      (c) => c.channelNumber == channelNumber);
                                  if (idx >= 0) {
                                    try {
                                      widget.mainListController.jumpToItem(
                                        index: idx,
                                        scrollController:
                                            widget.mainScrollController,
                                        alignment: 0.5,
                                      );
                                    } catch (_) {}
                                  }
                                });
                              },
                            );
                          },
                        ),
                        onTap: () {
                          if (widget.appState.dismissGuideOnSelect) {
                            Navigator.pop(context, index);
                          }
                          final cfgCmd = SXiSelectChannelCommand(
                            ChanSelectionType.tuneUsingChannelNumber,
                            program.channelNumber,
                            0xFF,
                            ChannelAttributes.all(),
                            AudioRoutingType.routeToAudio,
                          );
                          widget.deviceLayer.sendControlCommand(cfgCmd);
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
    bool initialFavoritesOnAir = false,
    required ScrollController mainScrollController,
    required ListController mainListController,
    required ScrollController categoryScrollController,
    required ListController categoryListController,
  }) async {
    return await showDialog<int>(
          barrierDismissible: true,
          context: context,
          builder: (BuildContext dialogContext) {
            // Ignore on-screen keyboard for now
            final mq = MediaQuery.of(dialogContext);
            return MediaQuery(
              data: mq.copyWith(viewInsets: EdgeInsets.zero),
              child: EpgDialog(
                appState: appState,
                sxiLayer: sxiLayer,
                deviceLayer: deviceLayer,
                initialCategory: initialCategory,
                initialFavoritesOnAir: initialFavoritesOnAir,
                mainScrollController: mainScrollController,
                mainListController: mainListController,
                categoryScrollController: categoryScrollController,
                categoryListController: categoryListController,
              ),
            );
          },
        ) ??
        0;
  }
}
