// Favorites Manager Dialog
import 'package:flutter/material.dart';
import 'package:orbit/app_state.dart';
import 'package:orbit/device_layer.dart';
import 'package:orbit/data/favorite.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

enum FavoritesSortBy { added, id, alphabetical }

class FavoritesManagerDialog extends StatefulWidget {
  final AppState appState;
  final DeviceLayer deviceLayer;
  // Optional: open on a specific tab and focus a specific favorite
  final FavoriteType? initialTab;
  final FavoriteType? initialFocusType;
  final int? initialFocusId;

  const FavoritesManagerDialog({
    super.key,
    required this.appState,
    required this.deviceLayer,
    this.initialTab,
    this.initialFocusType,
    this.initialFocusId,
  });

  @override
  State<FavoritesManagerDialog> createState() => _FavoritesManagerDialogState();
}

class _FavoritesManagerDialogState extends State<FavoritesManagerDialog>
    with SingleTickerProviderStateMixin {
  late List<Favorite> _workingFavorites;
  FavoritesSortBy _sortBy = FavoritesSortBy.added;
  bool _ascending = false; // default to newest first for Added
  late TabController _tabController;
  final ScrollController _scrollController = ScrollController();
  final ListController _listController = ListController();
  FavoriteType? _highlightType;
  int? _highlightId;

  @override
  void initState() {
    super.initState();
    _workingFavorites = List<Favorite>.from(widget.appState.favorites);
    final FavoriteType initialTabType =
        widget.initialTab ?? widget.initialFocusType ?? FavoriteType.song;
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: initialTabType == FavoriteType.song ? 0 : 1,
    );
    _highlightType = widget.initialFocusType;
    _highlightId = widget.initialFocusId;

    // Attempt to bring focused item into view after first frame using SuperSliverList
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_highlightType != null && _highlightId != null) {
        final int targetIndex = _indexInVisibleFavorites(
          type: _highlightType!,
          id: _highlightId!,
        );
        if (targetIndex >= 0) {
          try {
            _listController.jumpToItem(
              index: targetIndex,
              scrollController: _scrollController,
              alignment: 0.2,
            );
          } catch (_) {}
        }
      }
    });
  }

  void _removeAt(int index) {
    setState(() {
      _workingFavorites.removeAt(index);
    });
  }

  void _removeFavorite(Favorite favorite) {
    final int index = _workingFavorites
        .indexWhere((f) => f.type == favorite.type && f.id == favorite.id);
    if (index >= 0) {
      _removeAt(index);
    }
  }

  bool _hasChanges() {
    if (_workingFavorites.length != widget.appState.favorites.length) {
      return true;
    }
    for (final f in _workingFavorites) {
      final exists = widget.appState.favorites
          .any((x) => x.type == f.type && x.id == f.id);
      if (!exists) return true;
    }
    return false;
  }

  Future<bool> _confirmDiscardIfNeeded() async {
    if (!_hasChanges()) return true;
    final bool? discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text(
            'You have unsaved changes to your favorites. Do you want to discard them?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard == true;
  }

  Future<void> _saveAndClose() async {
    // Calculate what changed to send only the differences
    final List<Favorite> originalFavorites = widget.appState.favorites;
    final List<Favorite> newFavorites = _workingFavorites;

    // Find added favorites
    final List<Favorite> addedFavorites = newFavorites
        .where((newFav) => !originalFavorites.any((origFav) =>
            origFav.type == newFav.type && origFav.id == newFav.id))
        .toList();

    // Find removed favorites
    final List<Favorite> removedFavorites = originalFavorites
        .where((origFav) => !newFavorites.any(
            (newFav) => newFav.type == origFav.type && newFav.id == origFav.id))
        .toList();

    // Apply changes to app state
    widget.appState.replaceFavorites(List<Favorite>.from(_workingFavorites));

    try {
      // Send only the changes instead of resending the entire list
      if (addedFavorites.isNotEmpty) {
        final List<int> addedSongIds = addedFavorites
            .where((f) => f.type == FavoriteType.song)
            .map((f) => f.id)
            .toList();
        final List<int> addedArtistIds = addedFavorites
            .where((f) => f.type == FavoriteType.artist)
            .map((f) => f.id)
            .toList();
        widget.deviceLayer.addFavorites(addedSongIds, addedArtistIds);
      }

      if (removedFavorites.isNotEmpty) {
        final List<int> removedSongIds = removedFavorites
            .where((f) => f.type == FavoriteType.song)
            .map((f) => f.id)
            .toList();
        final List<int> removedArtistIds = removedFavorites
            .where((f) => f.type == FavoriteType.artist)
            .map((f) => f.id)
            .toList();
        widget.deviceLayer.removeFavorites(removedSongIds, removedArtistIds);
      }
    } catch (_) {}

    if (mounted) Navigator.of(context).pop(true);
  }

  int _indexInVisibleFavorites({required FavoriteType type, required int id}) {
    final List<Favorite> visibleFavorites = _getVisibleFavorites();
    return visibleFavorites.indexWhere((f) => f.type == type && f.id == id);
  }

  List<Favorite> _getVisibleFavorites() {
    final FavoriteType selectedType =
        _tabController.index == 0 ? FavoriteType.song : FavoriteType.artist;
    final List<Favorite> visibleFavorites = List<Favorite>.from(
        _workingFavorites.where((f) => f.type == selectedType));
    switch (_sortBy) {
      case FavoritesSortBy.added:
        if (!_ascending) {
          visibleFavorites.setAll(
            0,
            List<Favorite>.from(visibleFavorites.reversed),
          );
        }
        break;
      case FavoritesSortBy.id:
        visibleFavorites.sort((a, b) {
          final cmp = a.id.compareTo(b.id);
          return _ascending ? cmp : -cmp;
        });
        break;
      case FavoritesSortBy.alphabetical:
        int cmpAlpha(Favorite a, Favorite b) {
          final ap = a.displayPrimary.toLowerCase();
          final bp = b.displayPrimary.toLowerCase();
          final primaryCmp = ap.compareTo(bp);
          if (primaryCmp != 0) return primaryCmp;
          final as = (a.isSong ? a.displaySecondary : '').toLowerCase();
          final bs = (b.isSong ? b.displaySecondary : '').toLowerCase();
          return as.compareTo(bs);
        }
        visibleFavorites.sort((a, b) {
          final cmp = cmpAlpha(a, b);
          return _ascending ? cmp : -cmp;
        });
        break;
    }
    return visibleFavorites;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_hasChanges(),
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await _confirmDiscardIfNeeded()) {
          if (context.mounted) Navigator.of(context).pop(false);
        }
      },
      child: AlertDialog(
        title: Row(
          children: [
            const Expanded(
              child: Text(
                'Edit Favorites',
                overflow: TextOverflow.ellipsis,
                softWrap: false,
              ),
            ),
            Row(children: [
              TextButton(
                onPressed: _saveAndClose,
                child: const Text('Save'),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () async {
                  if (await _confirmDiscardIfNeeded()) {
                    if (context.mounted) Navigator.of(context).pop(false);
                  }
                },
              ),
            ]),
          ],
        ),
        content: SizedBox(
          width: 500,
          height: 600,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Row(
                  children: [
                    const Text('Sort by:'),
                    const SizedBox(width: 8),
                    DropdownButton<FavoritesSortBy>(
                      value: _sortBy,
                      items: const [
                        DropdownMenuItem(
                          value: FavoritesSortBy.added,
                          child: Text('Added'),
                        ),
                        DropdownMenuItem(
                          value: FavoritesSortBy.id,
                          child: Text('ID'),
                        ),
                        DropdownMenuItem(
                          value: FavoritesSortBy.alphabetical,
                          child: Text('Alphabetical'),
                        ),
                      ],
                      onChanged: (val) {
                        if (val == null) return;
                        setState(() => _sortBy = val);
                      },
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: _ascending ? 'Ascending' : 'Descending',
                      icon: Icon(
                        _ascending ? Icons.arrow_upward : Icons.arrow_downward,
                      ),
                      onPressed: () => setState(() {
                        _ascending = !_ascending;
                      }),
                    ),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TabBar(
                  controller: _tabController,
                  isScrollable: false,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 12.0),
                  tabs: [
                    Tab(
                      text:
                          'Songs (${_workingFavorites.where((f) => f.isSong).length}/${AppState.favoritesMaxPerTypeTotal})',
                    ),
                    Tab(
                      text:
                          'Artists (${_workingFavorites.where((f) => f.isArtist).length}/${AppState.favoritesMaxPerTypeTotal})',
                    ),
                  ],
                  onTap: (_) => setState(() {}),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _workingFavorites.isEmpty
                    ? const Center(child: Text('No favorites yet'))
                    : Builder(builder: (context) {
                        final List<Favorite> visibleFavorites =
                            _getVisibleFavorites();
                        return SuperListView.builder(
                          controller: _scrollController,
                          listController: _listController,
                          itemCount: visibleFavorites.length,
                          itemBuilder: (context, index) {
                            final fav = visibleFavorites[index];
                            final bool isFocused = _highlightType == fav.type &&
                                _highlightId == fav.id;
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Material(
                                  type: MaterialType.transparency,
                                  clipBehavior: Clip.hardEdge,
                                  child: ListTile(
                                    leading: Icon(
                                      fav.isSong
                                          ? Icons.music_note
                                          : Icons.person,
                                    ),
                                    title: Text(
                                        '${fav.displayPrimary} (${fav.id})'),
                                    subtitle: fav.isSong &&
                                            fav.displaySecondary.isNotEmpty
                                        ? Text(fav.displaySecondary)
                                        : null,
                                    selected: isFocused,
                                    selectedTileColor: Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withValues(alpha: 0.12),
                                    trailing: IconButton(
                                      tooltip: 'Remove',
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: () => _removeFavorite(fav),
                                    ),
                                  ),
                                ),
                                if (index < visibleFavorites.length - 1)
                                  const Divider(height: 1),
                              ],
                            );
                          },
                        );
                      }),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _scrollController.dispose();
    _listController.dispose();
    super.dispose();
  }
}

class FavoritesManagerDialogHelper {
  static Future<void> show({
    required BuildContext context,
    required AppState appState,
    required DeviceLayer deviceLayer,
    FavoriteType? showTab,
    FavoriteType? focusType,
    int? focusId,
  }) async {
    await showDialog<void>(
      barrierDismissible: true,
      context: context,
      builder: (context) => FavoritesManagerDialog(
        appState: appState,
        deviceLayer: deviceLayer,
        initialTab: showTab,
        initialFocusType: focusType,
        initialFocusId: focusId,
      ),
    );
  }
}
