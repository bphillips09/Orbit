// Channel Info Dialog, shows the channel info for a given channel
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:orbit/app_state.dart';
import 'package:orbit/metadata/channel_data.dart';
import 'package:orbit/device_layer.dart';
import 'package:orbit/sxi_command_types.dart';
import 'package:orbit/sxi_commands.dart';
import 'package:orbit/ui/album_art.dart';
import 'package:orbit/ui/channel_logo_image.dart';
import 'package:orbit/logging.dart';
import 'package:orbit/helpers.dart';

class ChannelInfoDialog extends StatefulWidget {
  final AppState appState;
  final int initialSid;
  final DeviceLayer deviceLayer;
  final void Function(int channelNumber)? onTuneAlign;

  const ChannelInfoDialog({
    super.key,
    required this.appState,
    required this.initialSid,
    required this.deviceLayer,
    this.onTuneAlign,
  });

  static Future<void> show(
    BuildContext context, {
    required AppState appState,
    required int sid,
    required DeviceLayer deviceLayer,
    void Function(int channelNumber)? onTuneAlign,
  }) async {
    final channel = appState.sidMap[sid];
    logger.t(channel?.channelShortDescription);
    logger.t(channel?.channelLongDescription);
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => ChannelInfoDialog(
        appState: appState,
        initialSid: sid,
        deviceLayer: deviceLayer,
        onTuneAlign: onTuneAlign,
      ),
    );
  }

  @override
  State<ChannelInfoDialog> createState() => _ChannelInfoDialogState();
}

class _ChannelInfoDialogState extends State<ChannelInfoDialog> {
  late int _currentSid;
  final List<int> _sidStack = <int>[];

  @override
  void initState() {
    super.initState();
    _currentSid = widget.initialSid;
    _sidStack.add(widget.initialSid);
  }

  void _openSimilarChannel(int sid) {
    _sidStack.add(sid);
    setState(() => _currentSid = sid);
  }

  void _goBack() {
    if (_sidStack.length > 1) {
      _sidStack.removeLast();
      setState(() => _currentSid = _sidStack.last);
    }
  }

  void _tuneTo(ChannelData channel) {
    final cfgCmd = SXiSelectChannelCommand(
      ChanSelectionType.tuneUsingChannelNumber,
      channel.channelNumber,
      0xFF,
      ChannelAttributes.all(),
      AudioRoutingType.routeToAudio,
    );
    widget.deviceLayer.sendControlCommand(cfgCmd);
    widget.onTuneAlign?.call(channel.channelNumber);
  }

  @override
  Widget build(BuildContext context) {
    final ChannelData? channel = widget.appState.sidMap[_currentSid];
    if (channel == null) {
      return AlertDialog(
        title: const Text('Channel Info'),
        content: const Text('Channel information is unavailable.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    }

    final List<int> channelLogoBytes =
        widget.appState.storageData.getImageForSid(channel.sid);
    final int currentProgramId = channel.currentPid;
    final List<int> albumArtBytes =
        widget.appState.imageMap[channel.sid]?[currentProgramId] ?? const [];

    final theme = Theme.of(context);

    final categoryName = widget.appState.categories[channel.catId] ?? '';

    return AlertDialog(
      title: Builder(
        builder: (context) {
          final MediaQueryData mediaQuery = MediaQuery.of(context);
          final double screenWidth = mediaQuery.size.width;
          final double screenHeight = mediaQuery.size.height;
          final double aspectRatio =
              screenWidth / (screenHeight == 0 ? 1.0 : screenHeight);

          final bool hasBack = _sidStack.length > 1;
          final bool usableAspect =
              hasBack ? aspectRatio >= 0.65 : aspectRatio >= 0.55;
          final bool canShowLogo = channelLogoBytes.isNotEmpty && usableAspect;
          final double logoMaxWidth = (screenWidth * 0.18).clamp(24.0, 128.0);

          return Stack(
            children: [
              // Keep content from sliding under the close button
              Padding(
                padding: const EdgeInsets.only(right: 48.0),
                child: Row(
                  children: [
                    if (hasBack) ...[
                      IconButton(
                        tooltip: 'Back',
                        onPressed: _goBack,
                        icon: const Icon(Icons.arrow_back),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            channel.channelName,
                            style: theme.textTheme.titleLarge,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            'Channel ${channel.channelNumber}',
                            style: theme.textTheme.bodySmall,
                          ),
                          if (categoryName.isNotEmpty)
                            Text(
                              'Category: $categoryName',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    if (canShowLogo)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: logoMaxWidth,
                        ),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: FittedBox(
                            fit: BoxFit.contain,
                              child: ChannelLogoImage(
                                bytes: Uint8List.fromList(channelLogoBytes),
                                fit: BoxFit.contain,
                                filterQuality: FilterQuality.medium,
                                gaplessPlayback: true,
                              ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          );
        },
      ),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Now Playing
              Text('Now Playing', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  AlbumArt(
                    size: 64,
                    cacheWidth: 128,
                    cacheHeight: 128,
                    imageBytes: albumArtBytes.isNotEmpty
                        ? Uint8List.fromList(albumArtBytes)
                        : null,
                    borderRadius: 8.0,
                    borderWidth: 1.0,
                    placeholder: Icon(
                      getCategoryIcon(categoryName),
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          channel.currentSong.isNotEmpty
                              ? channel.currentSong
                              : 'Unknown track',
                          style: theme.textTheme.titleSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          channel.currentArtist.isNotEmpty
                              ? channel.currentArtist
                              : 'Unknown artist',
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Text('About', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              // If both descriptions are empty, show a message
              if (channel.channelShortDescription.isEmpty &&
                  channel.channelLongDescription.isEmpty) ...[
                Text('No data yet.', style: theme.textTheme.bodyMedium),
                const SizedBox(height: 12),
              ] else ...[
                // Else show both descriptions
                if (channel.channelShortDescription.isNotEmpty) ...[
                  Text(channel.channelShortDescription,
                      style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 12),
                ],
                if (channel.channelLongDescription.isNotEmpty) ...[
                  Text(channel.channelLongDescription,
                      style: theme.textTheme.bodyMedium, softWrap: true),
                ],
              ],
              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Text('Similar Channels', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              if (channel.similarSids.isNotEmpty) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: channel.similarSids.map((sid) {
                    final ChannelData? similar = widget.appState.sidMap[sid];
                    final logo = similar != null
                        ? widget.appState.storageData
                            .getImageForSid(similar.sid)
                        : const <int>[];
                    final label = similar?.channelName ?? 'Channel $sid';

                    return ActionChip(
                      avatarBoxConstraints: logo.isEmpty
                          ? null
                          : const BoxConstraints(
                              maxWidth: 32,
                              maxHeight: 16,
                            ),
                      avatar: logo.isNotEmpty
                          ? SizedBox(
                              child: ChannelLogoImage(
                                bytes: Uint8List.fromList(logo),
                                fit: BoxFit.contain,
                                filterQuality: FilterQuality.medium,
                                gaplessPlayback: true,
                              ),
                            )
                          : const CircleAvatar(
                              child: Icon(Icons.radio, size: 16),
                            ),
                      label: Text(label, overflow: TextOverflow.ellipsis),
                      onPressed: () => _openSimilarChannel(sid),
                    );
                  }).toList(),
                ),
              ] else ...[
                Text('No data yet.', style: theme.textTheme.bodyMedium),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
      ),
      actions: [
        ElevatedButton.icon(
          onPressed: widget.appState.currentSid == channel.sid
              ? null
              : () => _tuneTo(channel),
          icon: const Icon(Icons.play_arrow),
          label: const Text('Tune'),
        ),
      ],
    );
  }
}
