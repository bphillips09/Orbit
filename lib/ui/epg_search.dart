// EPG Search Utils for searching the EPG
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:orbit/metadata/channel_data.dart';

class EpgSearchUtils {
  static final RegExp _wordRegex = RegExp(r"[A-Za-z0-9']+");
  static const Set<String> channelNameStopwords = {'channel'};

  static List<String> tokenizeQuery(String query) {
    if (query.isEmpty) return const [];
    return _wordRegex
        .allMatches(query)
        .map((m) => m.group(0)!.toLowerCase())
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
  }

  // Compute the search score for a given channel and query
  static double computeSearchScore(
    ChannelData channel,
    String lowerQuery, {
    required bool isNumeric,
  }) {
    if (isNumeric) {
      return channel.channelNumber.toString() == lowerQuery ? 10000.0 : 0.0;
    }

    final List<String> qTokens = tokenizeQuery(lowerQuery);
    if (qTokens.isEmpty) return 0.0;
    final List<String> strongTokens =
        qTokens.where((t) => t.length >= 3).toList(growable: false);

    if (strongTokens.isNotEmpty) {
      int strongMatches = 0;
      for (final t in strongTokens) {
        final double best = math.max(
          _bestSingleTokenScoreForText(channel.currentSong, t),
          math.max(
            _bestSingleTokenScoreForText(channel.currentArtist, t),
            _bestSingleTokenScoreForText(
              channel.channelName,
              t,
              ignoredTokens: channelNameStopwords,
            ),
          ),
        );
        if (best > 0) strongMatches++;
      }
      if (strongMatches == 0) return 0.0;
    }

    final double songScore = _scoreField(
      channel.currentSong,
      qTokens,
      fullLowerQuery: lowerQuery,
    );
    final double artistScore = _scoreField(
      channel.currentArtist,
      qTokens,
      fullLowerQuery: lowerQuery,
    );
    final double nameScore = _scoreField(
      channel.channelName,
      qTokens,
      ignoredTokens: channelNameStopwords,
      allowFullPhraseBoost: false,
    );

    double score = 1.0 * songScore + 0.95 * artistScore + 0.8 * nameScore;

    int fieldsMatched = 0;
    if (songScore > 0) fieldsMatched++;
    if (artistScore > 0) fieldsMatched++;
    if (nameScore > 0) fieldsMatched++;
    if (fieldsMatched >= 2) {
      score += 20.0 * (fieldsMatched - 1);
    }

    if (strongTokens.isNotEmpty) {
      int strongMatches = 0;
      for (final t in strongTokens) {
        final double best = math.max(
          _bestSingleTokenScoreForText(channel.currentSong, t),
          math.max(
            _bestSingleTokenScoreForText(channel.currentArtist, t),
            _bestSingleTokenScoreForText(
              channel.channelName,
              t,
              ignoredTokens: channelNameStopwords,
            ),
          ),
        );
        if (best > 0) strongMatches++;
      }
      final double coverage = strongMatches / strongTokens.length;
      score = score * (0.6 + 0.4 * coverage) +
          (math.max(0, strongMatches - 1) * 25.0);
    }

    return score;
  }

  // Check if a channel matches all tokens in the query
  static bool matchesAllTokens(ChannelData c, List<String> tokens) {
    for (final t in tokens) {
      final bool matched = _hasTokenWordOrPrefixMatch(c.currentSong, t) ||
          _hasTokenWordOrPrefixMatch(c.currentArtist, t) ||
          _hasTokenWordOrPrefixMatch(
            c.channelName,
            t,
            ignoredTokens: channelNameStopwords,
          );
      if (!matched) return false;
    }
    return true;
  }

  // Build highlighted spans for a given text and query
  static List<TextSpan> buildHighlightedSpans({
    required BuildContext context,
    required String text,
    required String query,
    Set<String>? ignoredTokens,
  }) {
    if (query.trim().isEmpty) {
      return [TextSpan(text: text)];
    }

    final List<String> queryTokens = tokenizeQuery(query);
    if (queryTokens.isEmpty) {
      return [TextSpan(text: text)];
    }

    final List<_TokenSpan> textWords = _tokenizeWithIndices(text);
    final Set<String> ignored =
        (ignoredTokens ?? const <String>{}).map((e) => e.toLowerCase()).toSet();

    final List<_Range> ranges = [];
    for (final w in textWords) {
      if (ignored.contains(w.valueLower)) continue;
      for (final token in queryTokens) {
        if (w.valueLower == token) {
          ranges.add(_Range(w.start, w.end));
          break;
        } else if (w.valueLower.startsWith(token)) {
          ranges.add(_Range(w.start, w.start + token.length));
        }
      }
    }

    if (ranges.isEmpty) {
      return [TextSpan(text: text)];
    }

    ranges.sort((a, b) => a.start.compareTo(b.start));
    final List<_Range> merged = [];
    for (final r in ranges) {
      if (merged.isEmpty || r.start > merged.last.end) {
        merged.add(_Range(r.start, r.end));
      } else {
        merged.last =
            _Range(merged.last.start, math.max(merged.last.end, r.end));
      }
    }

    final Color highlightColor = Theme.of(context).colorScheme.primary;
    final List<TextSpan> spans = [];
    int cursor = 0;
    for (final r in merged) {
      if (cursor < r.start) {
        spans.add(TextSpan(text: text.substring(cursor, r.start)));
      }
      spans.add(
        TextSpan(
          text: text.substring(r.start, r.end),
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: highlightColor,
          ),
        ),
      );
      cursor = r.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return spans;
  }

  // Tokenize the text with indices
  static List<_TokenSpan> _tokenizeWithIndices(String text) {
    final List<_TokenSpan> tokens = [];
    for (final match in _wordRegex.allMatches(text)) {
      final value = match.group(0)!;
      tokens.add(_TokenSpan(
        valueLower: value.toLowerCase(),
        start: match.start,
        end: match.end,
      ));
    }
    return tokens;
  }

  // Check if a text has a token word or prefix match
  static bool _hasTokenWordOrPrefixMatch(
    String text,
    String token, {
    Set<String>? ignoredTokens,
  }) {
    final Set<String> ignored =
        (ignoredTokens ?? const <String>{}).map((e) => e.toLowerCase()).toSet();
    final List<_TokenSpan> words = _tokenizeWithIndices(text);
    for (final w in words) {
      if (ignored.contains(w.valueLower)) continue;
      if (w.valueLower == token) return true;
      if (w.valueLower.startsWith(token)) return true;
    }
    return false;
  }

  // Score a field based on the query tokens
  static double _scoreField(
    String text,
    List<String> queryTokens, {
    Set<String>? ignoredTokens,
    bool allowFullPhraseBoost = true,
    String? fullLowerQuery,
  }) {
    if (queryTokens.isEmpty) return 0.0;
    final Set<String> ignored =
        (ignoredTokens ?? const <String>{}).map((e) => e.toLowerCase()).toSet();

    double score = 0.0;
    for (final String q in queryTokens) {
      final double tokenWeight = math.min(1.0, q.length / 3.0);
      final double bestForToken = _bestSingleTokenScoreForText(
        text,
        q,
        ignoredTokens: ignored,
      );
      score += bestForToken * tokenWeight;
    }

    if (allowFullPhraseBoost &&
        fullLowerQuery != null &&
        fullLowerQuery.isNotEmpty) {
      final lowerText = text.toLowerCase();
      if (lowerText == fullLowerQuery) {
        score += 120.0;
      } else if (lowerText.startsWith(fullLowerQuery)) {
        score += 50.0;
      } else if (lowerText.contains(fullLowerQuery)) {
        score += 18.0;
      }
    }

    return score;
  }

  // Score a single token for a given text
  static double _bestSingleTokenScoreForText(
    String text,
    String token, {
    Set<String>? ignoredTokens,
  }) {
    final Set<String> ignored =
        (ignoredTokens ?? const <String>{}).map((e) => e.toLowerCase()).toSet();
    double bestForToken = 0.0;
    final List<_TokenSpan> words = _tokenizeWithIndices(text);
    for (int i = 0; i < words.length; i++) {
      final w = words[i];
      if (ignored.contains(w.valueLower)) continue;
      if (w.valueLower == token) {
        double s = 100.0;
        if (w.start == 0) s += 10.0;
        bestForToken = math.max(bestForToken, s);
      } else if (w.valueLower.startsWith(token)) {
        double s = 60.0;
        if (w.start == 0) s += 8.0;
        bestForToken = math.max(bestForToken, s);
      } else if (w.valueLower.contains(token)) {
        bestForToken = math.max(bestForToken, 12.0);
      }
    }
    return bestForToken;
  }
}

class _TokenSpan {
  final String valueLower;
  final int start;
  final int end;
  _TokenSpan({
    required this.valueLower,
    required this.start,
    required this.end,
  });
}

class _Range {
  final int start;
  final int end;
  const _Range(this.start, this.end);
}
