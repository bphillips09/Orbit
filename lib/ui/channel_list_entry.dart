// Widget for displaying a channel list entry (EPG/Favorites)
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:orbit/ui/album_art.dart';
import 'package:orbit/ui/channel_logo_image.dart';

class ChannelListEntry extends StatelessWidget {
  final bool isNowPlaying;
  final Uint8List? albumArt;
  final Widget placeholder;
  final List<InlineSpan>? titleSpans;
  final String? titleText;
  final List<InlineSpan>? subtitleSpans;
  final String? subtitleText;
  final int channelNumber;
  final Uint8List? channelLogo;
  final List<InlineSpan>? channelNameSpans;
  final String? channelName;
  final IconButton? infoButton;
  final VoidCallback? onTap;
  final double compactWidthThreshold;

  const ChannelListEntry({
    super.key,
    required this.isNowPlaying,
    required this.albumArt,
    required this.placeholder,
    required this.channelNumber,
    required this.channelLogo,
    this.titleSpans,
    this.titleText,
    this.subtitleSpans,
    this.subtitleText,
    this.channelNameSpans,
    this.channelName,
    this.infoButton,
    this.onTap,
    this.compactWidthThreshold = 300,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final bool useCompactTrailing =
            constraints.maxWidth < compactWidthThreshold;
        return Container(
          decoration: BoxDecoration(
            color: isNowPlaying
                ? theme.colorScheme.primary.withValues(alpha: 0.05)
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
            contentPadding: const EdgeInsets.symmetric(horizontal: 16.0),
            selected: isNowPlaying,
            leading: !useCompactTrailing
                ? AlbumArt(
                    size: 50,
                    cacheWidth: 64,
                    cacheHeight: 64,
                    imageBytes: albumArt,
                    borderRadius: 4.0,
                    borderWidth: 1.0,
                    placeholder: placeholder,
                  )
                : null,
            title: _buildTitle(context),
            subtitle: _buildSubtitle(context),
            trailing: useCompactTrailing
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('Ch. $channelNumber'),
                          if (channelLogo == null)
                            _buildChannelName(context)
                          else
                            SizedBox(
                              height: 30,
                              width: 60,
                              child: ChannelLogoImage(
                                bytes: channelLogo!,
                                cacheHeight: 128,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                                filterQuality: FilterQuality.medium,
                                fallbackBuilder: _buildChannelName,
                              ),
                            ),
                        ],
                      ),
                    ],
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('Channel $channelNumber'),
                          if (channelLogo == null)
                            _buildChannelName(context)
                          else
                            SizedBox(
                              height: 30,
                              width: 80,
                              child: ChannelLogoImage(
                                bytes: channelLogo!,
                                cacheHeight: 128,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                                filterQuality: FilterQuality.medium,
                                fallbackBuilder: _buildChannelName,
                              ),
                            ),
                        ],
                      ),
                      if (infoButton != null) infoButton!,
                    ],
                  ),
            onTap: onTap,
          ),
        );
      },
    );
  }

  Widget _buildTitle(BuildContext context) {
    if (titleSpans != null && titleSpans!.isNotEmpty) {
      return Text.rich(
        TextSpan(children: titleSpans),
        overflow: TextOverflow.ellipsis,
      );
    }
    return Text(
      titleText ?? '',
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildSubtitle(BuildContext context) {
    if (subtitleSpans != null && subtitleSpans!.isNotEmpty) {
      return Text.rich(
        TextSpan(children: subtitleSpans),
        overflow: TextOverflow.ellipsis,
      );
    }
    return Text(
      subtitleText ?? '',
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildChannelName(BuildContext context) {
    if (channelNameSpans != null && channelNameSpans!.isNotEmpty) {
      return Text.rich(
        TextSpan(children: channelNameSpans),
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.end,
      );
    }
    return Text(
      channelName ?? '',
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.end,
    );
  }
}
