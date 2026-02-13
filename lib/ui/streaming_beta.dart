import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:orbit/app_state.dart';
import 'package:orbit/device_layer.dart';
import 'package:orbit/helpers.dart';
import 'package:orbit/logging.dart';
import 'package:orbit/sxi_commands.dart';
import 'package:orbit/sxi_indications.dart';
import 'package:orbit/storage/storage_data.dart';

class StreamingBetaPage extends StatefulWidget {
  final DeviceLayer deviceLayer;
  final AppState appState;
  const StreamingBetaPage(
      {super.key, required this.deviceLayer, required this.appState});

  @override
  State<StreamingBetaPage> createState() => _StreamingBetaPageState();
}

class _StreamingBetaPageState extends State<StreamingBetaPage> {
  // Default API host
  String get _defaultApiBaseUrl =>
      'https://streamingapi-emma23-gdg2-prod-onair.mountain.siriusxm.com';

  String _status = 'Idle';
  String? _cookieToken;
  bool _busy = false;

  List<int>? _latestDeviceState;
  List<int>? _latestSignedChallenge;
  StreamSubscription? _deviceSub;
  String? _latestChallenge;
  late final TextEditingController _challengeController;
  final Map<String, String> _cookies = <String, String>{};
  List<_StreamChannel> _channels = <_StreamChannel>[];
  final Map<String, Uint8List> _logoCache = <String, Uint8List>{};
  final Set<String> _logoFetching = <String>{};
  String _searchQuery = '';
  late final TextEditingController _searchController;
  final Map<String, String> _relativeUrls = <String, String>{};
  HeadlessInAppWebView? _headlessWebView;
  InAppWebViewController? _headlessController;
  Completer<void>? _headlessLoaded;
  bool _hlsIsPlaying = false;
  bool _isPaused = false;
  bool _isMuted = false;
  double _volume = 1.0;
  String? _lastHlsUrl;
  String? _currentChannelId;
  String? _nowTitle;
  String? _nowArtist;
  String? _nowArtUrl;
  bool _isScrubbing = false;
  double _scrubValue = 0.0;
  double? _pendingSeekTargetSec;
  double _posStart = 0.0;
  double _posEnd = 0.0;
  double _posCurrent = 0.0;
  Timer? _positionTimer;
  int _hlsFragStartMs = 0;
  int _hlsFragEndMs = 0;
  List<_NowCut> _cutMarkers = <_NowCut>[];
  final Map<String, _CutDetails> _cutDetailsCache = <String, _CutDetails>{};
  final Set<String> _cutDetailsFetching = <String>{};
  Timer? _seekNowPlayingDebounce;
  int _serverWallClockMs = 0;
  int _serverWallClockLocalMs = 0;
  int _nextCutEndMs = 0;
  int _npAnchorAbsMs = 0;
  double _npAnchorPosEndSec = 0.0;
  int _timelineNowOverrideMs = 0;
  int _liveDelayMs = 0;
  bool _showSeekPreview = false;
  String? _seekPreviewTitle;
  String? _seekPreviewArtist;
  String? _seekPreviewGuid;
  Timer? _nowPlayingTimer;
  final int _nowPlayingUpdateSec = 30;
  int _hlsFragSn = -1;
  int _hlsFragDurMs = 0;
  bool _didInitialResume = false;

  @override
  void initState() {
    super.initState();
    _challengeController = TextEditingController();
    _searchController = TextEditingController();
    // Load persisted token
    (() async {
      try {
        final saved = await widget.appState.storageData.load(
          SaveDataType.sxmToken,
          defaultValue: '',
        );
        String token = (saved is String) ? saved : '';
        if (token.isNotEmpty) {
          setState(() {
            _cookieToken = token;
            _cookies['SXM-TOKEN-ID'] = token;
          });
        }
      } catch (_) {}
    })();
    _deviceSub = widget.deviceLayer.messageStream.listen((message) {
      final payload = message.payload;
      if (payload is SXiAuthenticationIndication) {
        setState(() {
          _latestDeviceState = List<int>.from(payload.deviceState);
        });
        logger.i('AuthInd received: deviceState=$_latestDeviceState');
      } else if (payload is SXiIPAuthenticationIndication) {
        setState(() {
          _latestSignedChallenge = List<int>.from(payload.signedChallenge);
        });
        logger.i(
            'IPAuthInd received: signedChallenge len=${_latestSignedChallenge?.length ?? 0}');
      }
    });
  }

  Widget _buildChannelLogoPlaceholder(_StreamChannel ch) {
    return Container(
      height: 30,
      width: 80,
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        borderRadius: BorderRadius.circular(4),
      ),
      alignment: Alignment.center,
      child: Text(
        ch.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  List<_StreamChannel> _parseChannelsFromFullLineup(String body) {
    try {
      final dynamic root = jsonDecode(body);
      final modules = root['ModuleListResponse']?['moduleList']?['modules'];
      if (modules is! List) return <_StreamChannel>[];
      final List<_StreamChannel> out = <_StreamChannel>[];
      for (final m in modules) {
        final moduleResponse = m['moduleResponse'];
        final contentData = moduleResponse?['contentData'];
        final listing = contentData?['channelListing'];
        final channels = listing?['channels'];
        if (channels is! List) continue;
        for (final ch in channels) {
          final String channelId = (ch['channelId'] ?? '').toString();
          final String name = (ch['name'] ?? '').toString();
          final String number = (ch['channelNumber'] ?? '').toString();
          String? mref;
          try {
            final direct = ch['mref'] ?? ch['mRef'];
            if (direct != null) mref = direct.toString();
            final tune = ch['tune'] ?? ch['tuneData'] ?? ch['tuneInfo'];
            if ((mref == null || mref.isEmpty) && tune is Map) {
              final t = tune['mref'] ?? tune['mRef'];
              if (t != null) mref = t.toString();
            }
            if (mref == null || mref.isEmpty) {
              String? deepFind(dynamic node, int depth) {
                if (depth > 6 || node == null) return null;
                if (node is Map) {
                  for (final e in node.entries) {
                    final k = e.key?.toString();
                    if (k == 'mref' || k == 'mRef') {
                      final v = e.value;
                      if (v != null) {
                        final s = v.toString();
                        if (s.isNotEmpty) return s;
                      }
                    }
                    final r = deepFind(e.value, depth + 1);
                    if (r != null && r.isNotEmpty) return r;
                  }
                } else if (node is List) {
                  for (final it in node) {
                    final r = deepFind(it, depth + 1);
                    if (r != null && r.isNotEmpty) return r;
                  }
                }
                return null;
              }

              mref = deepFind(ch, 0);
            }
          } catch (_) {}
          String? logoUrl;
          try {
            final imgs = ch['images']?['images'];
            if (imgs is List && imgs.isNotEmpty) {
              // Prefer list view logo if present, else first
              final listLogo = imgs.firstWhere(
                  (e) => (e['name'] ?? '')
                      .toString()
                      .toLowerCase()
                      .contains('list view'),
                  orElse: () => imgs.first);
              logoUrl = (listLogo['url'] ?? '').toString();
            }
          } catch (_) {}
          if (channelId.isNotEmpty && name.isNotEmpty) {
            out.add(_StreamChannel(
                channelId: channelId,
                name: name,
                channelNumber: number,
                mref: (mref != null && mref.isNotEmpty) ? mref : null,
                logoUrl: logoUrl));
          }
        }
      }
      return out;
    } catch (e) {
      logger.w('Parse lineup error: $e');
      return <_StreamChannel>[];
    }
  }

  List<_StreamChannel> get _filteredChannels {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return _channels;
    return _channels.where((c) {
      final name = c.name.toLowerCase();
      final numStr = c.channelNumber.toLowerCase();
      return name.contains(q) || numStr.contains(q);
    }).toList();
  }

  String _resolveRelativeUrl(String url, {String? type}) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    if (url.startsWith('//')) return 'https:$url';
    final String? base = type != null ? _relativeUrls[type] : null;
    if (base != null && base.isNotEmpty) {
      if (url.startsWith('/')) return '$base$url';
      return '$base/$url';
    }
    final fallbackBase = _apiBaseUrl();
    if (url.startsWith('/')) return '$fallbackBase$url';
    return '$fallbackBase/$url';
  }

  String _expandRelativePlaceholders(String input) {
    return input.replaceAllMapped(RegExp(r'%([^%]+)%'), (m) {
      final key = m.group(1)!;
      final base = _relativeUrls[key];
      if (base != null && base.isNotEmpty) return base;
      return m.group(0)!;
    });
  }

  Future<void> _maybeFetchLogo(_StreamChannel ch) async {
    final url = ch.logoUrl;
    if (url == null || url.isEmpty) return;
    if (_logoCache.containsKey(ch.channelId)) return;
    if (_logoFetching.contains(ch.channelId)) return;
    _logoFetching.add(ch.channelId);
    try {
      final String resolved = _resolveRelativeUrl(url, type: 'Image');
      final uri = Uri.parse(resolved);
      final resp = await http.get(uri, headers: const {
        'Accept': 'image/*'
      }).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
        setState(() {
          _logoCache[ch.channelId] = Uint8List.fromList(resp.bodyBytes);
        });
      }
    } catch (e) {
      logger.d('Logo fetch failed for ${ch.channelId}: $e');
    } finally {
      _logoFetching.remove(ch.channelId);
    }
  }

  @override
  void dispose() {
    try {
      _nowPlayingTimer?.cancel();
    } catch (_) {}
    try {
      _seekNowPlayingDebounce?.cancel();
    } catch (_) {}
    _seekNowPlayingDebounce = null;
    try {
      _challengeController.dispose();
    } catch (_) {}
    try {
      _searchController.dispose();
    } catch (_) {}
    _deviceSub?.cancel();
    try {
      _stopHlsWebView(disposeOnly: true);
    } catch (_) {}
    super.dispose();
  }

  void _updateCookiesFromResponse(Map<String, String> headers) {
    try {
      final raw = headers['set-cookie'] ?? headers['Set-Cookie'];
      if (raw == null || raw.isEmpty) return;
      // Split on commas that start a new cookie
      final parts = raw.split(RegExp(r',(?=[A-Za-z0-9_\-]+=)'));
      for (final part in parts) {
        final first = part.trim().split(';').first;
        final eq = first.indexOf('=');
        if (eq <= 0) continue;
        final name = first.substring(0, eq).trim();
        final value = first.substring(eq + 1).trim();
        if (name.isNotEmpty && value.isNotEmpty) {
          _cookies[name] = value;
        }
      }
      logger
          .d('Streaming API: cookie jar now has: ${_cookies.keys.join(', ')}');
    } catch (_) {}
  }

  String? _tryGetJwtClaim(String jwt, String claim) {
    try {
      final parts = jwt.split('.');
      if (parts.length < 2) return null;
      final payloadB64 = parts[1];
      final normalized = base64Url.normalize(payloadB64);
      final jsonStr = utf8.decode(base64Url.decode(normalized));
      final obj = jsonDecode(jsonStr);
      if (obj is Map && obj[claim] != null) {
        return obj[claim].toString();
      }
    } catch (_) {}
    return null;
  }

  String? _deriveGupId() {
    // Prefer pause point cookie
    final pausePoint = _cookies['X-Mountain-PausePoint'];
    if (pausePoint != null && pausePoint.isNotEmpty) {
      final idx = pausePoint.indexOf(r'$$$');
      if (idx > 0) return pausePoint.substring(0, idx);
      // If the server returned it without metadata, still accept whole value
      if (pausePoint.startsWith('360L-')) return pausePoint;
    }
    final sxmData = _cookies['SXM-DATA'];
    if (sxmData != null && sxmData.isNotEmpty) {
      final pr = _tryGetJwtClaim(sxmData, 'pr');
      if (pr != null && pr.isNotEmpty) return pr;
    }
    return null;
  }

  String _buildCookieHeader() {
    if (_cookies.isEmpty) return '';
    return _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  bool _hasCookie(String name) {
    final v = _cookies[name];
    return v != null && v.isNotEmpty;
  }

  Map<String, String> _buildCommonHeaders({bool json = false}) {
    final headers = <String, String>{
      'Accept': json ? 'application/json' : '*/*',
      if (json) 'Content-Type': 'application/json; charset=UTF-8',
    };
    final radioId = widget.appState.radioIdString;
    if (radioId.isNotEmpty) {
      headers['X-SiriusXM-deviceId'] = radioId;
    }
    final ck = _buildCookieHeader();
    if (ck.isNotEmpty) headers['Cookie'] = ck;
    return headers;
  }

  void _logResponse(Uri uri, http.Response resp) {
    logger.i(
        'Streaming API: ${resp.request?.method ?? ''} $uri -> ${resp.statusCode} ${resp.reasonPhrase ?? ''} ct=${resp.headers['content-type']} len=${resp.body.length}');
    logger.d('Streaming API: response body: ${resp.body}');
    logger.d('Streaming API: response headers: ${resp.headers.toString()}');
    _updateCookiesFromResponse(resp.headers);
  }

  String _apiBaseUrl({String? baseOverride}) {
    if (baseOverride != null && baseOverride.isNotEmpty) return baseOverride;
    final hostMap = _cookies['SXMHOSTMAP'];
    if (hostMap != null && hostMap.isNotEmpty) return 'https://$hostMap';
    return _defaultApiBaseUrl;
  }

  Future<http.Response> _httpGet(String pathOrUrl,
      {Map<String, String>? extraHeaders,
      String? baseOverride,
      Duration timeout = const Duration(seconds: 10)}) async {
    final bool isAbsolute =
        pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://');
    final String base = _apiBaseUrl(baseOverride: baseOverride);
    final String full = isAbsolute ? pathOrUrl : '$base$pathOrUrl';
    final uri = Uri.parse(full);
    logger.i('Streaming API: GET $uri');
    final headers = _buildCommonHeaders(json: false)
      ..addAll(extraHeaders ?? {});
    final resp = await http.get(uri, headers: headers).timeout(timeout);
    _logResponse(uri, resp);
    return resp;
  }

  Future<http.Response> _httpPost(String pathWithQuery, Object body,
      {Map<String, String>? extraHeaders,
      Duration timeout = const Duration(seconds: 12)}) async {
    final uri = Uri.parse('${_apiBaseUrl()}$pathWithQuery');
    final bodyStr = body is String ? body : jsonEncode(body);
    logger.i('Streaming API: POST $uri');
    logger.d('Streaming API: request body: ${truncate(bodyStr)}');
    final headers = _buildCommonHeaders(json: true)..addAll(extraHeaders ?? {});
    logger.d('Streaming API: request headers: $headers');
    final resp =
        await http.post(uri, headers: headers, body: bodyStr).timeout(timeout);
    _logResponse(uri, resp);
    return resp;
  }

  Future<void> _sendSxiAuthSequence(String challengeHex) async {
    logger.i('SXi: Sequence step 1 - Send SXiDeviceAuthenticationCommand');
    widget.deviceLayer.sendControlCommand(SXiDeviceAuthenticationCommand());
    Future.delayed(const Duration(milliseconds: 500), () {
      logger.i(
          'SXi: Sequence step 2 (+500ms) - Send SXiDeviceAuthenticationCommand');
      widget.deviceLayer.sendControlCommand(SXiDeviceAuthenticationCommand());
    });
    final List<int> bytes = hexStringToBytes(challengeHex);
    Future.delayed(const Duration(milliseconds: 1000), () {
      logger.i(
          'SXi: Sequence step 3 (+1000ms) - Send SXiDeviceIPAuthenticationCommand with ${bytes.length} bytes');
      widget.deviceLayer
          .sendControlCommand(SXiDeviceIPAuthenticationCommand(bytes));
    });
  }

  Future<void> _downloadFullLineup() async {
    if (_busy) return;
    if ((_cookieToken ?? '').isEmpty &&
        !_cookies.keys.any((k) => k == 'SXM-TOKEN-ID')) {
      setState(() => _status = 'Token missing. Run auth flow first.');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Downloading full lineup...';
    });
    try {
      final body = {
        "moduleList": {
          "modules": [
            {
              "moduleType": "ChannelListing",
              "moduleArea": "Discovery",
              "moduleRequest": {
                "resultTemplate": "360L",
                "profileInfos": [],
                "alerts": [],
                "consumeRequests": []
              }
            }
          ]
        }
      };
      final resp = await _httpPost(
        '/rest/v3/experience/modules/get?type=2&full_lineup=true',
        body,
        extraHeaders: {'Accept': 'application/json'},
        timeout: const Duration(seconds: 30),
      );
      if (resp.statusCode == 200) {
        final int bytes = resp.bodyBytes.length;
        logger.d('Streaming API: full lineup body: ${resp.body}');
        Clipboard.setData(ClipboardData(text: resp.body));
        final parsed = _parseChannelsFromFullLineup(resp.body);
        setState(() {
          _channels = parsed;
          _status = 'Full lineup OK ($bytes bytes, ${parsed.length} channels)';
        });
      } else {
        logger.d('Streaming API: full lineup failed: ${resp.body}');
        setState(() => _status = 'Full lineup failed: ${resp.statusCode}');
      }
    } catch (e) {
      setState(() => _status = 'Full lineup error: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<bool> _ensureDeviceId(
      {Duration timeout = const Duration(seconds: 3)}) async {
    if (widget.appState.deviceId != 0) return true;
    logger.i(
        'SXi: deviceId is 0 — sending SXiDeviceAuthenticationCommand to fetch it');

    final completer = Completer<int>();
    late StreamSubscription sub;
    Timer? timer;
    void complete(int id) {
      if (!completer.isCompleted) completer.complete(id);
      timer?.cancel();
      sub.cancel();
    }

    timer = Timer(timeout, () => complete(0));
    sub = widget.deviceLayer.messageStream.listen((message) {
      final p = message.payload;
      if (p is SXiAuthenticationIndication) {
        try {
          // Update latest deviceState snapshot
          setState(() {
            _latestDeviceState = List<int>.from(p.deviceState);
          });
        } catch (_) {}
        // Try to use parsed deviceId if available
        final int parsedId =
            (p as dynamic).deviceId is int ? (p as dynamic).deviceId : 0;
        complete(parsedId);
      }
    });

    try {
      widget.deviceLayer.sendControlCommand(SXiDeviceAuthenticationCommand());
    } catch (e) {
      logger
          .w('SXi: failed to send DeviceAuthentication for deviceId fetch: $e');
    }

    final int id = await completer.future;
    if (id != 0) {
      logger.i('SXi: Retrieved deviceId=$id from AuthenticationIndication');
      try {
        widget.appState.updateDeviceId(id);
      } catch (_) {}
      return true;
    }
    logger.w('SXi: Timed out fetching deviceId from AuthenticationIndication');
    return false;
  }

  Future<List<int>?> _waitForDeviceState(
      {Duration timeout = const Duration(seconds: 5)}) async {
    final completer = Completer<List<int>?>();
    late StreamSubscription sub;
    Timer? timer;
    void complete(List<int>? v) {
      if (!completer.isCompleted) completer.complete(v);
      timer?.cancel();
      sub.cancel();
    }

    timer = Timer(timeout, () => complete(null));
    sub = widget.deviceLayer.messageStream.listen((message) {
      final p = message.payload;
      if (p is SXiAuthenticationIndication) {
        complete(List<int>.from(p.deviceState));
      }
    });
    return completer.future;
  }

  Future<List<int>?> _waitForSignedChallenge(
      {Duration timeout = const Duration(seconds: 5)}) async {
    final completer = Completer<List<int>?>();
    late StreamSubscription sub;
    Timer? timer;
    void complete(List<int>? v) {
      if (!completer.isCompleted) completer.complete(v);
      timer?.cancel();
      sub.cancel();
    }

    timer = Timer(timeout, () => complete(null));
    sub = widget.deviceLayer.messageStream.listen((message) {
      final p = message.payload;
      if (p is SXiIPAuthenticationIndication) {
        complete(List<int>.from(p.signedChallenge));
      }
    });
    return completer.future;
  }

  Future<void> _ensureDeviceStateForResume(
      {Duration timeout = const Duration(seconds: 2)}) async {
    final cur = _latestDeviceState;
    if (cur != null && cur.isNotEmpty) return;
    try {
      logger.i(
          'SXi: deviceState missing — sending SXiDeviceAuthenticationCommand to refresh it');
      widget.deviceLayer.sendControlCommand(SXiDeviceAuthenticationCommand());
    } catch (e) {
      logger.w('SXi: failed to send DeviceAuthentication for deviceState: $e');
      return;
    }
    final ds = await _waitForDeviceState(timeout: timeout);
    if (!mounted) return;
    if (ds != null && ds.isNotEmpty) {
      setState(() => _latestDeviceState = List<int>.from(ds));
    }
  }

  Future<void> _runFullAuthFlow() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Running full auth flow...';
      _latestDeviceState = null;
      _latestSignedChallenge = null;
      _cookieToken = null;
    });
    try {
      // Ensure we have a deviceId before any API calls
      await _ensureDeviceId();
      await _runConnectivity();
      await _fetchConfiguration();
      await _checkRadioConfig();
      await _resume();

      // Wait for device indications
      final deviceState = await _waitForDeviceState();
      if (deviceState == null || deviceState.isEmpty) {
        setState(() => _status = 'Timed out waiting for deviceState');
        return;
      }
      final signed = await _waitForSignedChallenge();
      if (signed == null || signed.isEmpty) {
        setState(() => _status = 'Timed out waiting for signedChallenge');
        return;
      }

      await _validateDeviceAuth();
    } catch (e) {
      setState(() => _status = 'Full flow error: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _fetchConfiguration() async {
    setState(() {
      _status = 'Fetching configuration...';
    });
    try {
      final resp = await _httpGet(
        '/rest/v2/experience/modules/get/configuration?app-region=US&&result-template=360l',
        timeout: const Duration(seconds: 10),
      );
      if (resp.statusCode != 200) {
        setState(() => _status = 'configuration failed: ${resp.statusCode}');
        return;
      }
      logger.d(
          'Streaming API: configuration body: ${truncate(resp.body, max: 4000)}');
      final dynamic root = jsonDecode(resp.body);
      final modules = root['ModuleListResponse']?['moduleList']?['modules'];
      if (modules is! List || modules.isEmpty) {
        setState(() => _status = 'configuration: no modules');
        return;
      }
      final module = modules.firstWhere(
          (m) => (m['moduleType'] ?? '') == 'Localization',
          orElse: () => modules.first);
      final rel = module['moduleResponse']?['configuration']?['components']
          ?.firstWhere((c) => (c['name'] ?? '') == 'relativeUrls',
              orElse: () => null);
      final settings = rel?['settings'];
      if (settings is List && settings.isNotEmpty) {
        final urls = settings.first['relativeUrls'];
        if (urls is List) {
          final Map<String, String> map = <String, String>{};
          for (final u in urls) {
            final n = (u['name'] ?? '').toString();
            final v = (u['url'] ?? '').toString();
            if (n.isNotEmpty && v.isNotEmpty) map[n] = v;
          }
          setState(() {
            _relativeUrls
              ..clear()
              ..addAll(map);
            _status = 'Configuration OK (${_relativeUrls.length} bases)';
          });
          return;
        }
      }
      setState(() => _status = 'configuration: no relativeUrls');
    } catch (e) {
      setState(() => _status = 'configuration error: $e');
    }
  }

  Future<void> _runConnectivity() async {
    setState(() {
      _busy = true;
      _status = 'Checking connectivity...';
    });
    try {
      final resp = await _httpGet('/assets/data/connectivity.json',
          timeout: const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        setState(() => _status = 'Connectivity OK (200)');
      } else {
        setState(() => _status = 'Connectivity failed: ${resp.statusCode}');
      }
    } catch (e) {
      logger.e('Streaming API: connectivity error', error: e);
      setState(() => _status = 'Connectivity error: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _checkRadioConfig() async {
    final radioId = widget.appState.radioIdString;
    if (radioId.isEmpty) {
      setState(() => _status = 'Radio ID unavailable');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Checking radioConfig...';
    });
    try {
      final resp = await _httpGet(
          '/rest/v5/experience/radioConfig?radioId=$radioId',
          timeout: const Duration(seconds: 8));
      if (resp.statusCode != 200) {
        setState(() => _status = 'radioConfig failed: ${resp.statusCode}');
        return;
      }
      final dynamic body = jsonDecode(resp.body);
      final ipFlag =
          (body['radioConfigResponse']?['radioIPFlag']?['ipFlag'] ?? false) ==
              true;
      setState(() => _status = 'radioConfig OK; ipFlag=$ipFlag');
    } catch (e) {
      logger.e('Streaming API: radioConfig error', error: e);
      setState(() => _status = 'radioConfig error: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _resume() async {
    await _resumeInternal(allowAuthFlow: !_didInitialResume);
  }

  Future<void> _resumeInternal({
    required bool allowAuthFlow,
    bool allowTuneFallback = true,
    String? channelId,
    String contentType = 'live',
  }) async {
    // Cancel any pending now-playing refresh when tuning/resuming
    try {
      _nowPlayingTimer?.cancel();
    } catch (_) {}
    _nowPlayingTimer = null;

    // Clear prior tune results so we can detect when resume didn't provide Live/HLS.
    _lastHlsUrl = null;
    _currentChannelId = null;

    // NOTE: Do not override radioId/deviceId here; they must match the current session/token.

    final radioId = widget.appState.radioIdString;
    final deviceId = widget.appState.deviceId.toString();
    if (radioId.isEmpty || deviceId.isEmpty) {
      setState(() => _status = 'Missing radioId or deviceId');
      return;
    }

    await _ensureDeviceStateForResume();

    final gupId = _deriveGupId() ?? '';
    final deviceState = _latestDeviceState;
    final extraHeaders = <String, String>{
      if (deviceState != null && deviceState.isNotEmpty)
        'X-SiriusXM-deviceState': bytesToHex(deviceState, upperCase: true),
      'X-SiriusXM-deviceMode': 'standard',
    };

    setState(() {
      _busy = true;
      _status = 'POST /resume...';
    });
    bool scheduleFullLineup = false;
    bool resumeHadHls = false;
    try {
      final body = {
        'moduleList': {
          'modules': [
            {
              'moduleRequest': {
                'profileAuth': {
                  'cloud': false,
                  'overrideActiveGupId': gupId,
                  'gupId': gupId,
                  'oemId': '${radioId}OEMID_TEST_1'
                },
                'deviceInfo': {
                  'supportsAddlChannels': true,
                  'resultTemplate': 'tablet',
                  'appRegion': 'US',
                  'pushNotificationDeviceToken': '""',
                  'deviceId': deviceId,
                  'clientDeviceId': radioId,
                  'osLevelPush': 'off',
                  'deviceSignature': deviceId,
                  'language': 'en',
                  'deviceVersion': '1',
                  'mobileCarrier': '',
                  'platform': 'InCar',
                  'clientCapabilities': [
                    'relativeUrls',
                    'podcast',
                    'profiles2.0',
                    'seededRadio',
                    'addlChannels',
                    'profiles2.0',
                    'podcast',
                    'comingledSortOrder'
                  ]
                }
              }
            }
          ]
        }
      };

      final String path = channelId == null
          ? '/rest/v3/resume'
          : '/rest/v3/resume?channelId=${Uri.encodeComponent(channelId)}&contentType=${Uri.encodeComponent(contentType)}';

      final resp = await _httpPost(path, body, extraHeaders: extraHeaders);
      final sc = resp.statusCode;
      logger.d(
          'Streaming API: resume response headers: ${resp.headers.toString()}');
      if (sc != 200) {
        setState(() => _status = 'resume failed: $sc ${resp.reasonPhrase}');
        return;
      }

      Clipboard.setData(ClipboardData(text: resp.body));

      final dynamic json = jsonDecode(resp.body);
      final msgs = (json['ModuleListResponse']?['messages']) as List?;
      if (msgs != null && msgs.isNotEmpty) {
        final msg0 = msgs.first;
        final code = msg0['code'];
        final message = msg0['message'];
        setState(() => _status = 'resume: $message ($code)');
        logger.d('Streaming API: resume: ${resp.body})');
        if (code == 201) {
          // Authentication required
          if (allowAuthFlow) {
            await _deviceChallenge();
          } else {
            setState(() => _status =
                'resume: Authentication required (201) — run Authorize From Device');
          }
        } else {
          // Successful resume
          final bool firstTime = !_didInitialResume;
          // Only mark "initial resume done" when the server reports success
          if (code == 100) _didInitialResume = true;
          // If this is the first successful resume and channels not loaded yet, mark for lineup
          if (firstTime && _channels.isEmpty) {
            scheduleFullLineup = true;
          }
        }
      } else {
        setState(() => _status = 'resume: unexpected response');
      }

      // Try fetching the Primary LARGE HLS playlist from resume response
      try {
        final ok = await _tryFetchPrimaryLargeFromResumeJson(json);
        resumeHadHls = ok;
        if (ok) {
          await _playHlsWebView();
          // Auto-fetch now playing on tune
          try {
            await _fetchNowPlaying();
          } catch (_) {}
        }
      } catch (e) {
        logger.d('HLS fetch attempt error: $e');
      }
    } catch (e) {
      logger.e('Streaming API: resume error', error: e);
      setState(() => _status = 'resume error: $e');
    } finally {
      setState(() => _busy = false);
    }

    // If resume didn't include Live/HLS, start a tune session
    if (allowTuneFallback &&
        channelId != null &&
        contentType == 'live' &&
        !resumeHadHls &&
        ((_lastHlsUrl ?? '').isEmpty)) {
      logger.i(
          'Resume returned no Live/HLS; starting tune fallback (channelId=$channelId)');
      try {
        await _tuneNowPlayingLiveByChannelId(channelId);
      } catch (e) {
        logger.w('Tune fallback failed: $e');
      }
    }

    // Run lineup download after busy clears
    if (scheduleFullLineup) {
      try {
        await _downloadFullLineup();
      } catch (_) {}
    }
  }

  Future<bool> _tryFetchPrimaryLargeFromResumeJson(dynamic root) async {
    try {
      final modules =
          root['ModuleListResponse']?['moduleList']?['modules'] as List?;
      if (modules == null || modules.isEmpty) return false;
      final live = modules.firstWhere(
        (m) => (m['moduleType'] ?? '') == 'Live',
        orElse: () => null,
      );
      if (live == null) return false;
      final liveData = live['moduleResponse']?['liveChannelData'];
      if (liveData == null) return false;
      final infos = liveData['hlsAudioInfos'] ??
          liveData['customAudioInfos'] ??
          liveData['audioInfos'];
      if (infos is! List || infos.isEmpty) return false;
      Map? selected;
      for (final info in infos) {
        final name = (info['name'] ?? '').toString().toLowerCase();
        final size = (info['size'] ?? '').toString().toUpperCase();
        if (name == 'primary' && size == 'LARGE') {
          selected = info as Map;
          break;
        }
      }
      selected ??= infos.firstWhere(
          (i) => ((i['name'] ?? '').toString().toLowerCase() == 'primary'),
          orElse: () => infos.first);
      final rawUrl = ((selected ?? const {})['url'] ?? '').toString();
      if (rawUrl.isEmpty) return false;
      String url = _expandRelativePlaceholders(rawUrl);
      final consumption = (liveData['hlsConsumptionInfo'] ?? '').toString();
      if (consumption.isNotEmpty) {
        if (consumption.startsWith('?')) {
          url = url.contains('?')
              ? '$url&${consumption.substring(1)}'
              : '$url$consumption';
        } else {
          url = url.contains('?') ? '$url&$consumption' : '$url?$consumption';
        }
      }
      setState(() {
        _lastHlsUrl = url;
        try {
          _currentChannelId = (liveData['channelId'] ?? '').toString();
        } catch (_) {}
      });
      setState(() => _status = 'Fetching HLS (primary LARGE)...');
      final resp = await _httpGet(url, extraHeaders: const {
        'Accept':
            'audio/aac, audio/x-aac, audio/mp4, application/vnd.apple.mpegurl, application/x-mpegURL, */*'
      });
      logger.i('HLS GET $url -> ${resp.statusCode}');
      logger.d('HLS response: ${resp.body}');
      setState(
          () => _status = 'HLS: ${resp.statusCode} ${resp.reasonPhrase ?? ''}');
      return resp.statusCode == 200;
    } catch (e) {
      logger.d('Failed to fetch Primary LARGE HLS: $e');
      return false;
    }
  }

  Map<String, dynamic>? _findLiveModule(dynamic root) {
    try {
      final modules =
          root['ModuleListResponse']?['moduleList']?['modules'] as List?;
      if (modules == null || modules.isEmpty) return null;
      final live = modules.firstWhere(
        (m) => (m['moduleType'] ?? '') == 'Live',
        orElse: () => null,
      );
      if (live is Map<String, dynamic>) return live;
      if (live is Map) return Map<String, dynamic>.from(live);
    } catch (_) {}
    return null;
  }

  Future<void> _ensureRelativeUrlsLoaded() async {
    if (_relativeUrls.isNotEmpty) return;
    try {
      await _fetchConfiguration();
    } catch (_) {}
  }

  Future<bool> _tuneNowPlayingLiveByMref(String mref) async {
    final m = mref.trim();
    if (m.isEmpty) return false;
    if (_busy) {
      logger.w('Tune skipped (mref=$m): busy');
      return false;
    }
    setState(() {
      _busy = true;
      _status = 'GET tune now-playing-live (mref=$m)...';
    });
    try {
      // For playback we need HLS urls, so request them directly
      final path =
          '/rest/v2/experience/modules/tune/now-playing-live?mref=${Uri.encodeQueryComponent(m)}&hls_output_mode=all&marker_mode=all_separate&ccRequestType=AUDIO_VIDEO&result-template=tablet';
      final resp = await _httpGet(path, timeout: const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        setState(() => _status = 'tune failed: ${resp.statusCode}');
        return false;
      }
      final dynamic json = jsonDecode(resp.body);
      final live = _findLiveModule(json);
      if (live == null) {
        setState(() => _status = 'tune OK but no Live module in response');
        return false;
      }

      await _ensureRelativeUrlsLoaded();

      // Try to play immediately if the response happened to include HLS urls
      final okHls = await _tryFetchPrimaryLargeFromResumeJson(json);
      if (okHls) {
        await _playHlsWebView();
        try {
          await _fetchNowPlaying();
        } catch (_) {}
        return true;
      }

      setState(() => _status = 'tune OK (Live) but no HLS urls in response');
      return false;
    } catch (e) {
      setState(() => _status = 'tune error: $e');
      return false;
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<bool> _tuneNowPlayingLiveByChannelId(String channelId) async {
    final cid = channelId.trim();
    if (cid.isEmpty) return false;
    if (_busy) {
      logger.w('Tune skipped (channelId=$cid): busy');
      return false;
    }
    setState(() {
      _busy = true;
      _status = 'GET tune now-playing-live (channelId=$cid)...';
    });
    try {
      final path = '/rest/v2/experience/modules/tune/now-playing-live'
          '?channelId=${Uri.encodeComponent(cid)}'
          '&hls_output_mode=all&marker_mode=all_separate'
          '&ccRequestType=AUDIO_VIDEO&result-template=tablet';
      final resp = await _httpGet(path, timeout: const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        setState(() => _status = 'tune failed: ${resp.statusCode}');
        return false;
      }
      final dynamic json = jsonDecode(resp.body);
      final live = _findLiveModule(json);
      if (live == null) {
        setState(() => _status = 'tune OK but no Live module in response');
        return false;
      }

      await _ensureRelativeUrlsLoaded();

      // If the service already included HLS infos, we can start playback immediately
      final okHls = await _tryFetchPrimaryLargeFromResumeJson(json);
      if (okHls) {
        await _playHlsWebView();
        try {
          await _fetchNowPlaying();
        } catch (_) {}
        return true;
      }

      setState(() => _status = 'tune OK (Live) but no HLS urls in response');
      return false;
    } catch (e) {
      setState(() => _status = 'tune error: $e');
      return false;
    } finally {
      setState(() => _busy = false);
    }
  }

  // Build a minimal HTML page that plays HLS via native support or hls.js fallback
  String _buildHlsPlayerHtml() {
    return r'''<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <style>
    html, body { margin:0; padding:0; background:#000; height:100%; }
    #root { position:relative; width:100%; height:100%; }
    video { position:absolute; top:0; left:0; width:100%; height:100%; background:#000; object-fit:contain; }
    #overlay { position:absolute; inset:0; display:flex; align-items:center; justify-content:center; background:rgba(0,0,0,0.35); color:#fff; font-family: -apple-system, BlinkMacSystemFont, Arial, sans-serif; font-size:14px; cursor:pointer; z-index:9999; }
    #overlay.hidden { display:none; }
    #btn { padding:8px 12px; border:1px solid rgba(255,255,255,0.5); border-radius:6px; background:rgba(0,0,0,0.4); color:#fff; }
  </style>
  <script src="https://cdn.jsdelivr.net/npm/hls.js@1.6.12"></script>
  <script>
    console.log('HLS.js loaded');
    console.log('UA', navigator.userAgent);
    window._hls = null;
    function hideOverlay(){ var ov=document.getElementById('overlay'); if(ov){ ov.classList.add('hidden'); } }
    function showOverlay(){ var ov=document.getElementById('overlay'); if(ov){ ov.classList.remove('hidden'); } }
    function userUnmute(){
      console.log('userUnmute');
      var v=document.getElementById('v');
      try { v.muted = false; v.volume = 1.0; } catch(e){}
      v.play().catch(function(e){ console.log('userUnmute play error', e); });
      hideOverlay();
    }
    document.addEventListener('DOMContentLoaded', function(){
      var v=document.getElementById('v');
      if(!v) return;
      v.addEventListener('playing', hideOverlay);
      v.addEventListener('pause', showOverlay);
      var evs=['loadstart','loadedmetadata','loadeddata','canplay','canplaythrough','play','playing','pause','waiting','stalled','suspend','ended','seeking','seeked','durationchange','volumechange','error'];
      evs.forEach(function(n){ v.addEventListener(n,function(){ console.log('video event', n, 'rs='+v.readyState, 'ns='+v.networkState, 't='+v.currentTime.toFixed(2)); if(n==='error' && v.error){ console.log('video mediaError code', v.error.code); } }); });
    });

    function getCookie(name){
      try {
        var m = document.cookie.match(new RegExp('(?:^|; )'+name.replace(/([.$?*|{}()\[\]\\\/\+^])/g,'\\$1')+'=([^;]*)'));
        return m ? decodeURIComponent(m[1]) : '';
      } catch(e) { return ''; }
    }

    // Custom loader that rewrites AES-128 key URL using SXMHOSTMAP and SXMKEYPATH cookies
    class KeyRewritingLoader extends Hls.DefaultConfig.loader {
      constructor(config){ super(config); }
      load(context, config, callbacks){
        try {
          var url = context && context.url ? String(context.url) : '';
          if (context && context.type === 'key' && url && !/^https?:\/\//i.test(url)) {
            var host = getCookie('SXMHOSTMAP');
            var keyPath = getCookie('SXMKEYPATH');
            if (host && keyPath) {
              var base = 'https://' + host.replace(/\/+$/,'') + '/' + keyPath.replace(/^\/+|\/+$/g,'');
              var newUrl = base + '/' + url.replace(/^\/+/, '');
              console.log('Rewrite KEY url', url, '->', newUrl);
              context.url = newUrl;
            } else {
              console.log('KEY rewrite skipped; missing SXMHOSTMAP/SXMKEYPATH cookies');
            }
          }
        } catch(e) { console.log('loader rewrite err', e); }
        super.load(context, config, callbacks);
      }
    }
    function playUrl(url) {
      console.log('playUrl', url);
      const video = document.getElementById('v');
      try { video.crossOrigin = 'use-credentials'; } catch(e){
        console.log('video.crossOrigin error', e);
      }
      try { video.autoplay = true; } catch(e){
        console.log('video.autoplay error', e);
      }
      try { video.muted = true; } catch(e){ console.log('video.muted set true error', e); }
      var canNative = '';
      try { canNative = video.canPlayType('application/vnd.apple.mpegURL'); } catch(e){}
      console.log('canPlayType(application/vnd.apple.mpegURL)=', canNative);
      if (canNative === 'probably' || canNative === 'maybe') {
        console.log('Using native HLS');
        video.src = url;
        try { video.load(); } catch(e){}
        try { video.muted = false; video.volume = 1.0; } catch(e){}
        showOverlay();
      } else if (window.Hls && Hls.isSupported()) {
        console.log('Using hls.js (MSE)');
        if (window._hls) { try { window._hls.destroy(); } catch(e){} }
        const hls = new Hls({
          debug: true,
          enableWorker: false,
          loader: KeyRewritingLoader,
          backBufferLength: 300,
          xhrSetup: function(xhr) {
            xhr.withCredentials = true;
            try { xhr.setRequestHeader('Accept', 'audio/aac, audio/x-aac, audio/mp4, application/vnd.apple.mpegurl, application/x-mpegURL, */*'); } catch(e){}
            try {
              if (window._sxmHeaders) {
                for (var k in window._sxmHeaders) {
                  if (Object.prototype.hasOwnProperty.call(window._sxmHeaders, k)) {
                    xhr.setRequestHeader(k, String(window._sxmHeaders[k]));
                  }
                }
              }
            } catch(e){}
          }
        });
        window._hls = hls;
        hls.on(Hls.Events.MEDIA_ATTACHED, function(){ console.log('HLS media attached'); });
        hls.on(Hls.Events.MANIFEST_LOADING, function(_, data){ console.log('HLS manifest loading', data && data.url ? data.url : ''); });
        hls.on(Hls.Events.MANIFEST_LOADED, function(_, data){
          console.log('HLS manifest loaded', (data && data.levels ? data.levels.length : 0)+' levels');
          try {
            if (data && data.levels && data.levels.length > 0) {
              console.log('Levels:', data.levels.map(function(l){ return (l.bitrate||0)+'bps'; }).join(','));
              // Start at lowest level to minimize decode issues
              hls.currentLevel = data.levels.length - 1;
            }
          } catch(e) { console.log('set currentLevel err', e); }
        });
        hls.on(Hls.Events.LEVEL_LOADED, function(_, data){ console.log('HLS level loaded', data && data.details ? (data.details.totalduration||0).toFixed(1)+'s' : ''); });
        hls.on(Hls.Events.FRAG_LOADED, function(_, data){ console.log('HLS frag loaded', data && data.frag ? data.frag.sn : ''); });
        hls.on(Hls.Events.ERROR, function(_, data){
          console.log('HLS error', data && data.type, data && data.details, data && data.response && data.response.code);
          if (data && data.fatal) {
            console.log('fatal -> recover');
            try { hls.recoverMediaError(); } catch(e){}
            showOverlay();
          }
        });
        hls.loadSource(url);
        hls.attachMedia(video);
        hls.on(Hls.Events.MANIFEST_PARSED, function(){ console.log('HLS.js manifest parsed'); showOverlay(); });
      } else if (video.canPlayType('application/vnd.apple.mpegURL')) {
        console.log('Using native HLS');
        video.src = url;
        try { video.load(); } catch(e){}
        try { video.muted = false; video.volume = 1.0; } catch(e){}
        showOverlay();
      } else {
        console.log('No HLS support');
      }
    }
    function _seekable(){
      try {
        var v=document.getElementById('v');
        if (v.seekable && v.seekable.length>0) {
          return { start: v.seekable.start(0), end: v.seekable.end(0) };
        }
      } catch(e){}
      return null;
    }
    function seekBy(delta){
      try {
        var v=document.getElementById('v');
        var r=_seekable(); if(!r){ console.log('no seekable range'); return; }
        var t=(isFinite(v.currentTime) ? v.currentTime : r.end) + (delta||0);
        if (t < r.start) t = r.start;
        if (t > r.end) t = r.end - 0.25;
        console.log('seekBy', delta, '->', t.toFixed(2), 'range', r.start.toFixed(2), r.end.toFixed(2));
        v.currentTime = t;
      } catch(e){ console.log('seekBy err', e); }
    }
    function goLive(){
      try {
        var v=document.getElementById('v');
        var r=_seekable(); if(!r){ console.log('no seekable range'); return; }
        var t = (window._hls && typeof window._hls.liveSyncPosition==='number') ? window._hls.liveSyncPosition : (r.end - 0.25);
        console.log('goLive ->', t.toFixed(2));
        v.currentTime = t;
      } catch(e){ console.log('goLive err', e); }
    }
    function stopPlayback() {
      console.log('stopPlayback');
      const video = document.getElementById('v');
      try { video.pause(); } catch(e){
        console.log('video.pause error', e);
      }
      try { video.removeAttribute('src'); } catch(e){
        console.log('video.removeAttribute error', e);
      }
      try { video.load(); } catch(e){
        console.log('video.load error', e);
      }
      if (window._hls) { try { window._hls.destroy(); } catch(e){
        console.log('window._hls.destroy error', e);
      } window._hls = null; }
      showOverlay();
    }

    function pausePlayback(){
      try { document.getElementById('v').pause(); } catch(e){ console.log('pause err', e); }
    }
    function resumePlayback(){
      try {
        var v=document.getElementById('v');
        v.muted = false; v.volume = 1.0;
        v.play().catch(function(e){ console.log('resume play err', e); });
      } catch(e){ console.log('resume err', e); }
    }
    function setMuted(m){
      try {
        var v=document.getElementById('v');
        v.muted = !!m;
        if (!m) { v.volume = 1.0; }
      } catch(e){ console.log('setMuted err', e); }
    }
    function setVolume(x){
      try {
        var v=document.getElementById('v');
        var vol = Math.max(0, Math.min(1, Number(x)));
        v.volume = vol;
        if (vol > 0) v.muted = false;
      } catch(e){ console.log('setVolume err', e); }
    }
    function getPosition(){
      try {
        var v=document.getElementById('v');
        var r=_seekable();
        var s = r ? r.start : 0;
        var e = r ? r.end : 0;
        var c = (typeof v.currentTime==='number' && isFinite(v.currentTime)) ? v.currentTime : 0;
        return JSON.stringify({start:s, end:e, current:c});
      } catch(e){ return '{"start":0,"end":0,"current":0}'; }
    }
    function seekTo(t){
      try { var v=document.getElementById('v'); v.currentTime = Number(t)||0; } catch(e){ console.log('seekTo err', e); }
    }
  </script>
  <title>HLS Player</title>
  </head>
  <body>
    <div id="root">
      <video id="v" playsinline autoplay muted controls></video>
      <div id="overlay" onclick="userUnmute()"><div id="btn">Tap to Unmute & Play</div></div>
    </div>
  </body>
</html>''';
  }

  Future<void> _seedCookiesForUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      final String domain = uri.host;
      final int expires =
          DateTime.now().add(const Duration(days: 7)).millisecondsSinceEpoch;
      for (final entry in _cookies.entries) {
        if (entry.value.isEmpty) continue;
        await CookieManager.instance().setCookie(
          url: WebUri(url),
          name: entry.key,
          value: entry.value,
          domain: domain,
          path: '/',
          isSecure: true,
          isHttpOnly: false,
          sameSite: HTTPCookieSameSitePolicy.NONE,
          expiresDate: expires,
        );
      }
      // Also seed cookies for the KEY host if provided via SXMHOSTMAP cookie
      final String? keyHost = _cookies['SXMHOSTMAP'];
      if (keyHost != null && keyHost.isNotEmpty) {
        final String keyBase = 'https://$keyHost/';
        for (final entry in _cookies.entries) {
          if (entry.value.isEmpty) continue;
          await CookieManager.instance().setCookie(
            url: WebUri(keyBase),
            name: entry.key,
            value: entry.value,
            domain: keyHost,
            path: '/',
            isSecure: true,
            isHttpOnly: false,
            sameSite: HTTPCookieSameSitePolicy.NONE,
            expiresDate: expires,
          );
        }
      }
    } catch (e) {
      logger.d('Cookie seeding failed: $e');
    }
  }

  Future<void> _ensureHeadlessWebView() async {
    if (_headlessWebView != null &&
        _headlessController != null &&
        _headlessLoaded != null) {
      await _headlessLoaded!.future;
      return;
    }
    _headlessLoaded = Completer<void>();
    _headlessWebView = HeadlessInAppWebView(
      initialData: InAppWebViewInitialData(data: _buildHlsPlayerHtml()),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        transparentBackground: true,
        allowsInlineMediaPlayback: true,
        useOnLoadResource: true,
        useOnDownloadStart: true,
        useShouldInterceptAjaxRequest: true,
        useShouldInterceptFetchRequest: true,
        allowContentAccess: true,
        databaseEnabled: true,
        domStorageEnabled: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      ),
      onWebViewCreated: (controller) {
        _headlessController = controller;
      },
      // onLoadStop handled below to also inject helpers
      onReceivedServerTrustAuthRequest: (controller, challenge) async {
        return ServerTrustAuthResponse(
            action: ServerTrustAuthResponseAction.PROCEED);
      },
      onConsoleMessage: (controller, consoleMessage) {
        logger.d('HLS WebView: ${consoleMessage.message}');
      },
      onReceivedError: (controller, request, error) {
        logger.e('Received error: ${error.description}');
      },
      onLoadStop: (controller, url) async {
        // Mark headless WebView ready
        if (!(_headlessLoaded?.isCompleted ?? true)) {
          _headlessLoaded?.complete();
        }
        // Inject helper to read current fragment PDT window
        try {
          await controller.evaluateJavascript(source: r"""
            (function(){
              if (!window._hlsFragInfo) { window._hlsFragInfo = { startMs:0, endMs:0, hasPdt:false, sn:-1, durMs:0, changeAt:0 }; }
              function _installFragHook(){
                try {
                  if (!window.Hls || !window._hls) return;
                  var h = window._hls; if (h.__fragHooked) return;
                  h.__fragHooked = true;
                  h.on(Hls.Events.FRAG_CHANGED, function(_, data){
                    try {
                      var frag = data && data.frag ? data.frag : null;
                      var durMs = Math.round(((frag && frag.duration)||0)*1000);
                      var pdtVal = frag ? frag.programDateTime : null;
                      var pdt = (typeof pdtVal==='number') ? pdtVal : (pdtVal ? new Date(pdtVal).getTime() : NaN);
                      var start = !isNaN(pdt) ? pdt : Date.now();
                      var end = start + durMs;
                      window._hlsFragInfo = { startMs:start, endMs:end, hasPdt:!isNaN(pdt), sn:(frag?frag.sn:-1), durMs:durMs, changeAt:Date.now() };
                    } catch(e){}
                  });
                } catch(e){}
              }
              function _extractFromDetails(){
                try {
                  var h=window._hls;
                  if (!h || !h.levels || h.levels.length===0) { return; }
                  var level = h.levels[h.currentLevel >=0 ? h.currentLevel : 0];
                  var details = level && level.details ? level.details : (h.levelController && h.levelController.levels && h.levelController.levels[h.currentLevel] && h.levelController.levels[h.currentLevel].details);
                  if (!details || !Array.isArray(details.fragments) || details.fragments.length===0) { return; }
                  var now = Date.now();
                  for (var i=0;i<details.fragments.length;i++){
                    var f = details.fragments[i];
                    var pdt = (typeof f.programDateTime==='number') ? f.programDateTime : (f.programDateTime ? new Date(f.programDateTime).getTime() : NaN);
                    if (!isNaN(pdt)){
                      var start = pdt;
                      var durMs = Math.round((f.duration||0)*1000);
                      var end = start + durMs;
                      if (now >= start && now < end) {
                        window._hlsFragInfo = { startMs:start, endMs:end, hasPdt:true, sn:(f.sn||-1), durMs:durMs, changeAt:(window._hlsFragInfo && window._hlsFragInfo.changeAt)||0 };
                        break;
                      }
                    }
                  }
                } catch(e) {}
              }
              function _tick(){ _installFragHook(); _extractFromDetails(); }
              if (!window._fragInfoInterval){ window._fragInfoInterval = setInterval(_tick, 1000); }
              _tick();
            })();
          """);
        } catch (_) {}
      },
    );
    await _headlessWebView!.run();
    await _headlessLoaded!.future;
  }

  Future<void> _playHlsWebView() async {
    final url = _lastHlsUrl;
    if (url == null || url.isEmpty) return;
    setState(() => _status = 'Preparing WebView HLS...');
    try {
      // Ensure cookies are available to the WebView for all HLS requests
      await _seedCookiesForUrl(url);
      await _ensureHeadlessWebView();
      await _headlessController?.evaluateJavascript(
          source: "playUrl('${url.replaceAll("'", "%27")}')");
      try {
        _positionTimer?.cancel();
      } catch (_) {}
      _positionTimer = Timer.periodic(const Duration(seconds: 1), (t) async {
        try {
          final jsonStr = await _headlessController?.evaluateJavascript(
              source: 'getPosition()');
          if (jsonStr is String && jsonStr.isNotEmpty) {
            final map = jsonDecode(jsonStr) as Map<String, dynamic>;
            setState(() {
              _posStart = (map['start'] as num).toDouble();
              _posEnd = (map['end'] as num).toDouble();
              _posCurrent = (map['current'] as num).toDouble();
            });
            final int? serverNowMs = _estimatedServerNowMs();
            if (serverNowMs != null && _posEnd > _posStart) {
              final int heardNowMs = (_liveDelayMs > 0)
                  ? (serverNowMs - _liveDelayMs)
                  : serverNowMs;
              _npAnchorAbsMs = heardNowMs;
              _npAnchorPosEndSec = _posEnd;
            }
          }
          // Also pull HLS.js fragment PDT window if available
          try {
            final fragInfo = await _headlessController?.evaluateJavascript(
                source:
                    '(function(){ return JSON.stringify(window._hlsFragInfo||{startMs:0,endMs:0,hasPdt:false,sn:-1,durMs:0}); })()');
            if (fragInfo is String && fragInfo.isNotEmpty) {
              final map2 = jsonDecode(fragInfo) as Map<String, dynamic>;
              setState(() {
                _hlsFragStartMs = (map2['startMs'] as num?)?.toInt() ?? 0;
                _hlsFragEndMs = (map2['endMs'] as num?)?.toInt() ?? 0;
                _hlsFragSn = (map2['sn'] as num?)?.toInt() ?? -1;
                _hlsFragDurMs = (map2['durMs'] as num?)?.toInt() ?? 0;
              });
            }
          } catch (_) {}
        } catch (_) {}
      });
      setState(() {
        _hlsIsPlaying = true;
        _status = 'HLS playing (WebView)';
      });
    } catch (e) {
      logger.e('HLS WebView play error: $e');
      setState(() => _status = 'HLS WebView play error: $e');
    }
  }

  Future<void> _stopHlsWebView({bool disposeOnly = false}) async {
    try {
      if (!disposeOnly) {
        await _headlessController?.evaluateJavascript(source: 'stopPlayback()');
      }
      _hlsIsPlaying = false;
      try {
        _seekNowPlayingDebounce?.cancel();
      } catch (_) {}
      _seekNowPlayingDebounce = null;
      try {
        _positionTimer?.cancel();
      } catch (_) {}
      _positionTimer = null;
      try {
        _nowPlayingTimer?.cancel();
      } catch (_) {}
      _nowPlayingTimer = null;
      try {
        await _headlessWebView?.dispose();
      } catch (_) {}
      _headlessWebView = null;
      _headlessController = null;
      _headlessLoaded = null;
      if (!disposeOnly) setState(() => _status = 'HLS stopped (WebView)');
    } catch (e) {
      if (!disposeOnly) setState(() => _status = 'HLS WebView stop error: $e');
    }
  }

  // Removed legacy just_audio playback. Using WebView-based playback instead.

  Future<void> _fetchNowPlaying() async {
    final channelId = _currentChannelId;
    if (channelId == null || channelId.isEmpty) {
      setState(() => _status = 'Now Playing: missing channelId');
      return;
    }
    final String expectedChannel = channelId;

    int normalizeLiveDelayMs(dynamic v) {
      final int? n = (v is num) ? v.toInt() : int.tryParse('$v');
      if (n == null || n <= 0) return 0;
      if (n < 10000) return n * 1000;
      return n;
    }

    final int serverGuessMs = _estimatedServerNowMs() ??
        DateTime.now().toUtc().millisecondsSinceEpoch;
    int playbackGuessMs = serverGuessMs;
    final int? playerAbsGuess = _absoluteMsForPlayerSec(_posCurrent);
    if (playerAbsGuess != null) {
      playbackGuessMs = playerAbsGuess;
    } else if (_liveDelayMs > 0) {
      playbackGuessMs = serverGuessMs - _liveDelayMs;
    }

    int lookbackSec = 300;
    try {
      if (_posEnd > _posStart) {
        final int bufSec = (_posEnd - _posStart).ceil();
        // Cap to something reasonable so we don't request gigantic timelines
        lookbackSec = (bufSec + 60).clamp(300, 2 * 60 * 60);
      }
    } catch (_) {}

    // Fetch cue points timeline
    final ts = DateTime.fromMillisecondsSinceEpoch(playbackGuessMs, isUtc: true)
        .subtract(Duration(seconds: lookbackSec))
        .toIso8601String();
    final pathTimeline = '/rest/v2/experience/modules/tune/now-playing-live'
        '?channelId=${Uri.encodeComponent(channelId)}'
        '&timestamp=${Uri.encodeComponent(ts)}'
        '&hls_output_mode=none&marker_mode=cue_points_only'
        '&ccRequestType=AUDIO_VIDEO&result-template=tablet';
    try {
      final resp = await _httpGet(pathTimeline,
          extraHeaders: const {'Accept': 'application/json'});
      logger.d(
          'NP: timeline GET bytes=${resp.bodyBytes.length} sc=${resp.statusCode}');
      if (resp.statusCode != 200) {
        setState(() => _status = 'Now Playing failed: ${resp.statusCode}');
        _scheduleNextNowPlaying(seconds: 10, onlyIfChannel: expectedChannel);
        return;
      }
      final dynamic root = jsonDecode(resp.body);
      final modules =
          root['ModuleListResponse']?['moduleList']?['modules'] as List?;
      try {
        final uf = modules?.firstWhere(
                (m) => (m['updateFrequency'] ?? '') != '',
                orElse: () => {})['updateFrequency'] ??
            root['ModuleListResponse']?['updateFrequency'];
        final ufInt = (uf is num) ? uf.toInt() : int.tryParse('$uf');
        if (ufInt != null) {
          logger.i('NP: server updateFrequency=$ufInt');
        }
      } catch (_) {}

      // Determine server wall clock for alignment
      int serverNowMs = 0;
      try {
        final wcStr = (root['ModuleListResponse']?['wallClockRenderTime'] ??
                modules?.firstWhere(
                    (m) =>
                        (m['wallClockRenderTime'] ?? '').toString().isNotEmpty,
                    orElse: () => {})['wallClockRenderTime'])
            ?.toString();
        if (wcStr != null && wcStr.isNotEmpty) {
          serverNowMs = DateTime.parse(_fixIsoTz(wcStr)).millisecondsSinceEpoch;
        }
      } catch (_) {}
      if (serverNowMs == 0) {
        serverNowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      }
      // Record server clock and local anchor to estimate current server time
      _serverWallClockMs = serverNowMs;
      _serverWallClockLocalMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      logger.i(
          'NP: serverNow=${_formatHms(serverNowMs)} (anchor local=${_formatHms(_serverWallClockLocalMs)})');

      String? currentAssetGuid;
      int? currentEndMs;
      int? nextChangeMs;
      final List<_NowCut> cuts = <_NowCut>[];
      int compareNowMs = serverNowMs;

      if (modules == null) {
        logger.w('NP: timeline has no modules');
      } else {
        for (final m in modules) {
          if ((m['moduleType'] ?? '') != 'Live') continue;
          final live = m['moduleResponse']?['liveChannelData'];
          if (live == null) {
            logger.w('NP: Live module missing liveChannelData');
            continue;
          }
          try {
            final int liveDelayMs = normalizeLiveDelayMs(live['liveDelay']);
            if (liveDelayMs > 0) {
              _liveDelayMs = liveDelayMs;
              logger.i(
                  'NP: liveDelay=${(liveDelayMs / 1000.0).toStringAsFixed(0)}s');
            }
          } catch (_) {}

          final int? playerAbsNowMs = _absoluteMsForPlayerSec(_posCurrent);
          if (playerAbsNowMs != null) {
            compareNowMs = playerAbsNowMs;
          } else if (_liveDelayMs > 0) {
            compareNowMs = serverNowMs - _liveDelayMs;
          } else {
            compareNowMs = serverNowMs;
          }
          if (compareNowMs > serverNowMs + 5000) compareNowMs = serverNowMs;
          _timelineNowOverrideMs = compareNowMs;
          logger.i(
              'NP: compareNow=${_formatHms(compareNowMs)} (serverNow=${_formatHms(serverNowMs)})');

          final cuePointList = live['cuePointList'];
          final cuePoints =
              cuePointList is Map ? cuePointList['cuePoints'] : null;
          if (cuePoints is List) {
            logger.i('NP: cuePoints count=${cuePoints.length}');
            try {
              final Map<String, int> byLayer = <String, int>{};
              for (final cp in cuePoints.whereType<Map>()) {
                final layer = (cp['layer'] ?? '').toString();
                byLayer[layer] = (byLayer[layer] ?? 0) + 1;
              }
              logger.i('NP: cuePoints by layer=${byLayer.toString()}');
              final sorted =
                  List<Map>.from(cuePoints.whereType<Map>().toList());
              sorted.sort((a, b) => ((a['time'] ?? 0) as num)
                  .compareTo(((b['time'] ?? 0) as num)));
              if (sorted.isNotEmpty) {
                final firstT = ((sorted.first['time'] ?? 0) as num).toInt();
                final lastT = ((sorted.last['time'] ?? 0) as num).toInt();
                logger.i(
                    'NP: cuePoints window ${_formatHms(firstT)} .. ${_formatHms(lastT)}');
              }
            } catch (_) {}
          }
          if (cuePoints is List && cuePoints.isNotEmpty) {
            final List<Map<String, dynamic>> cps = cuePoints
                .whereType<Map>()
                .where((e) => (e['layer'] ?? '') == 'cut')
                .map((e) => e as Map<String, dynamic>)
                .toList();
            cps.sort((a, b) =>
                ((a['time'] ?? 0) as num).compareTo(((b['time'] ?? 0) as num)));

            final Map<String, int> startByGuid = <String, int>{};

            for (final cp in cps) {
              final guid = (cp['assetGUID'] ?? '').toString();
              final evt = (cp['event'] ?? '').toString();
              final t = ((cp['time'] ?? 0) as num).toInt();
              if (guid.isEmpty) continue;
              if (evt == 'START') {
                startByGuid[guid] = t;
              } else if (evt == 'END') {
                final s = startByGuid.remove(guid);
                if (s != null && t > s) {
                  final cached = _cutDetailsCache[guid];
                  cuts.add(_NowCut(
                      assetGuid: guid,
                      startMs: s,
                      endMs: t,
                      durationSec: (t - s) / 1000.0,
                      title: cached?.title ?? '',
                      artist: cached?.artist ?? ''));
                }
              }
              // Track the next change boundary
              if (t > compareNowMs) {
                if (nextChangeMs == null || t < nextChangeMs) nextChangeMs = t;
              }
            }

            String? lastGuid;
            int? lastStart;
            for (final cp in cps) {
              final guid = (cp['assetGUID'] ?? '').toString();
              final evt = (cp['event'] ?? '').toString();
              final t = ((cp['time'] ?? 0) as num).toInt();
              if (evt == 'START' && t <= compareNowMs) {
                if (lastStart == null || t >= lastStart) {
                  lastStart = t;
                  lastGuid = guid;
                }
              }
            }
            if (lastGuid != null) {
              currentAssetGuid = lastGuid;
              for (final cp in cps) {
                if ((cp['assetGUID'] ?? '') == lastGuid &&
                    (cp['event'] ?? '') == 'END') {
                  currentEndMs = ((cp['time'] ?? 0) as num).toInt();
                }
              }
              logger.i(
                  'NP: selected current START guid=$lastGuid end=${_formatHms(currentEndMs)}');
            }

            try {
              final before = cps
                  .where((cp) =>
                      ((cp['time'] ?? 0) as num).toInt() <= compareNowMs)
                  .toList();
              final after = cps
                  .where(
                      (cp) => ((cp['time'] ?? 0) as num).toInt() > compareNowMs)
                  .toList();
              final String dbgBefore = before
                  .take(3)
                  .map((cp) =>
                      '${cp['event']} ${_formatHms(((cp['time'] ?? 0) as num).toInt())}')
                  .join(', ');
              final String dbgAfter = after
                  .take(3)
                  .map((cp) =>
                      '${cp['event']} ${_formatHms(((cp['time'] ?? 0) as num).toInt())}')
                  .join(', ');
              logger.i('NP: sample before=[$dbgBefore] after=[$dbgAfter]');
            } catch (_) {}
          } else {
            logger.w('NP: no cuePoints found in timeline');
          }
        }
      }

      // Update timeline UI
      cuts.sort((a, b) => a.startMs.compareTo(b.startMs));
      setState(() {
        _cutMarkers = cuts;
      });

      // If we have a current asset, fetch its details using assetGUID
      String? title;
      String? artist;
      String? artUrl;
      if (currentAssetGuid != null) {
        logger.i(
            'NP: currentGuid=$currentAssetGuid end=${_formatHms(currentEndMs)} nextChange=${_formatHms(nextChangeMs)}');
        final details =
            await _fetchCutDetails(channelId, currentAssetGuid, cache: true);
        if (details != null) {
          title = details.title;
          artist = details.artist;
          artUrl = details.artUrl;
        } else {
          logger.w('NP: details not found for guid=$currentAssetGuid');
        }
      } else {
        logger.w('NP: no currentGuid from cuePoints, fallback to all_separate');
        try {
          final pathFull = '/rest/v2/experience/modules/tune/now-playing-live'
              '?channelId=${Uri.encodeComponent(channelId)}'
              '&hls_output_mode=none&marker_mode=all_separate'
              '&ccRequestType=AUDIO_VIDEO&result-template=tablet';
          final r2 = await _httpGet(pathFull,
              extraHeaders: const {'Accept': 'application/json'});
          logger.d(
              'NP: fallback GET bytes=${r2.bodyBytes.length} sc=${r2.statusCode}');
          if (r2.statusCode == 200) {
            logger.d('NP: fallback body: ${truncate(r2.body, max: 4000)}');
            final dynamic body = jsonDecode(r2.body);
            final mods =
                body['ModuleListResponse']?['moduleList']?['modules'] as List?;
            String? bestGuid;
            int? bestStart;
            if (mods != null) {
              for (final m in mods) {
                if ((m['moduleType'] ?? '') != 'Live') continue;
                final liveData = m['moduleResponse']?['liveChannelData'];
                if (liveData == null) continue;
                final lists = (liveData['markerLists'] as List?) ?? const [];
                for (final ml in lists) {
                  if ((ml['layer'] ?? '') != 'cut') continue;
                  final markers = (ml['markers'] as List?) ?? const [];
                  for (final mk in markers) {
                    final guid = (mk['assetGUID'] ?? '').toString();
                    final tAbs =
                        (mk['timestamp']?['absolute'] ?? '').toString();
                    int tMs = 0;
                    try {
                      if (tAbs.isNotEmpty) {
                        tMs = DateTime.parse(_fixIsoTz(tAbs))
                            .millisecondsSinceEpoch;
                      } else {
                        tMs = ((mk['time'] ?? 0) as num).toInt();
                      }
                    } catch (_) {}
                    if (guid.isEmpty || tMs <= 0 || tMs > serverNowMs) {
                      continue;
                    }
                    if (bestStart == null || tMs >= bestStart) {
                      bestStart = tMs;
                      bestGuid = guid;
                    }
                  }
                }
              }
            }

            if (bestGuid != null) {
              logger.i(
                  'NP fallback: bestGuid=$bestGuid start=${_formatHms(bestStart)}');
              final details =
                  await _fetchCutDetails(channelId, bestGuid, cache: true);
              if (details != null) {
                title = details.title;
                artist = details.artist;
                artUrl = details.artUrl;
              } else {
                logger.w('NP fallback: details not found for guid=$bestGuid');
              }
            } else {
              logger.w('NP fallback: no bestGuid determined');
            }
          }
        } catch (_) {}
      }

      setState(() {
        _nowTitle = title;
        _nowArtist = artist;
        _nowArtUrl = artUrl;
        // Refresh cached title/artist in timeline list when possible
        if (currentAssetGuid != null) {
          for (int i = 0; i < cuts.length; i++) {
            final c = cuts[i];
            if (c.assetGuid == currentAssetGuid) {
              cuts[i] = _NowCut(
                assetGuid: c.assetGuid,
                startMs: c.startMs,
                endMs: c.endMs,
                durationSec: c.durationSec,
                title: (title ?? c.title),
                artist: (artist ?? c.artist),
              );
              break;
            }
          }
        }
        _cutMarkers = cuts;
        _status = 'Now Playing: ${title ?? '-'} • ${artist ?? '-'}';
        _nextCutEndMs = (currentEndMs ?? nextChangeMs) ?? 0;
      });
      logger.i('NP: set nextCutEndMs=${_formatHms(_nextCutEndMs)}');
      if (_nextCutEndMs == 0) {
        logger.w('NP: nextCutEndMs is 0; no future cut boundary found.');
      }

      // Schedule next update when playback reaches the next boundary
      int delaySec = _nowPlayingUpdateSec;
      final int? scheduleAt = currentEndMs ?? nextChangeMs;
      if (scheduleAt != null && scheduleAt > compareNowMs) {
        final int deltaMs = scheduleAt - compareNowMs + 400;
        delaySec = (deltaMs / 1000.0).clamp(1, 120).ceil();
      }
      logger.i(
          'NP: schedule delaySec=$delaySec (compareNow=${_formatHms(_timelineNowOverrideMs)} target=${_formatHms(scheduleAt)})');
      _scheduleNextNowPlaying(
          seconds: delaySec, onlyIfChannel: expectedChannel);
    } catch (e) {
      setState(() => _status = 'Now Playing error: $e');
      logger.w('NP: exception $e');
      _scheduleNextNowPlaying(seconds: 10, onlyIfChannel: expectedChannel);
    }
  }

  Future<_CutDetails?> _fetchCutDetails(String channelId, String assetGuid,
      {bool cache = false}) async {
    try {
      final path = '/rest/v2/experience/modules/tune/now-playing-live'
          '?channelId=${Uri.encodeComponent(channelId)}'
          '&assetGUID=${Uri.encodeComponent(assetGuid)}'
          '&hls_output_mode=none&marker_mode=all_separate'
          '&ccRequestType=AUDIO_VIDEO&result-template=tablet';
      final resp = await _httpGet(path,
          extraHeaders: const {'Accept': 'application/json'});
      if (resp.statusCode != 200) return null;
      logger.d('NP: cut details body: ${truncate(resp.body, max: 4000)}');
      final dynamic root = jsonDecode(resp.body);
      final modules =
          root['ModuleListResponse']?['moduleList']?['modules'] as List?;
      String? title;
      String? artist;
      String? artUrl;
      if (modules != null) {
        for (final m in modules) {
          if ((m['moduleType'] ?? '') != 'Live') continue;
          final liveData = m['moduleResponse']?['liveChannelData'];
          if (liveData == null) continue;
          final lists = (liveData['markerLists'] as List?) ?? const [];
          for (final ml in lists) {
            if ((ml['layer'] ?? '') != 'cut') continue;
            final markers = (ml['markers'] as List?) ?? const [];
            for (final mk in markers) {
              if ((mk['assetGUID'] ?? '') != assetGuid) continue;
              final cut = mk['cut'];
              if (cut != null) {
                title = (cut['title'] ?? '').toString();
                final arts = (cut['artists'] as List?) ?? const [];
                if (arts.isNotEmpty) {
                  artist = (arts.first['name'] ?? '').toString();
                }
                try {
                  final albumArts =
                      (cut['album']?['creativeArts'] as List?) ?? const [];
                  for (final a in albumArts) {
                    final rel = (a['relativeUrl'] ?? '').toString();
                    final abs = (a['url'] ?? '').toString();
                    String resolved = '';
                    if (abs.isNotEmpty &&
                        (abs.startsWith('http://') ||
                            abs.startsWith('https://'))) {
                      resolved = abs;
                    } else if (rel.isNotEmpty) {
                      String expanded = _expandRelativePlaceholders(rel);
                      if (!(expanded.startsWith('http://') ||
                          expanded.startsWith('https://'))) {
                        expanded =
                            _resolveRelativeUrl(expanded, type: 'Album_Art');
                      }
                      if (expanded.startsWith('http://') ||
                          expanded.startsWith('https://')) {
                        resolved = expanded;
                      }
                    }
                    if (resolved.isNotEmpty) {
                      artUrl = resolved;
                      break;
                    }
                  }
                } catch (_) {}
              }
            }
          }
        }
      }
      if (title == null && artist == null && artUrl == null) return null;
      final details = _CutDetails(
        title: title ?? '',
        artist: artist ?? '',
        artUrl: artUrl ?? '',
      );
      if (cache) {
        _cutDetailsCache[assetGuid] = details;
      }
      return details;
    } catch (_) {
      return null;
    }
  }

  void _scheduleNextNowPlaying({int? seconds, String? onlyIfChannel}) {
    try {
      _nowPlayingTimer?.cancel();
    } catch (_) {}
    _nowPlayingTimer = null;
    if (!_hlsIsPlaying) return;
    if ((_currentChannelId ?? '').isEmpty) return;
    if (onlyIfChannel != null && _currentChannelId != onlyIfChannel) return;
    final int delaySec = seconds ?? _nowPlayingUpdateSec;
    _nowPlayingTimer = Timer(Duration(seconds: delaySec), () {
      if (!mounted) return;
      if (!_hlsIsPlaying) return;
      if (onlyIfChannel != null && _currentChannelId != onlyIfChannel) return;
      _fetchNowPlaying();
    });
    logger.d('Now Playing: scheduled next update in ${delaySec}s');
  }

  int? _absoluteMsForPlayerSec(double playerSec) {
    if (_npAnchorAbsMs == 0) return null;
    final double endAtAnchor = _npAnchorPosEndSec;
    if (!(endAtAnchor.isFinite) || endAtAnchor <= 0) return null;
    final double deltaSec = endAtAnchor - playerSec;
    final int absMs = (_npAnchorAbsMs - (deltaSec * 1000.0)).round();
    return absMs;
  }

  _NowCut? _cutForAbsMs(int absMs) {
    if (_cutMarkers.isEmpty) return null;
    _NowCut? candidate;
    for (final c in _cutMarkers) {
      if (c.startMs <= absMs) candidate = c;
      if (c.startMs > absMs) break;
    }
    if (candidate == null) return null;
    if (absMs <= candidate.endMs) return candidate;
    return null;
  }

  void _updateSeekPreviewForPlayerSec(double playerSec) {
    final int? absMs = _absoluteMsForPlayerSec(playerSec);
    if (absMs == null) return;
    final _NowCut? cut = _cutForAbsMs(absMs);
    if (cut == null) return;
    final _CutDetails? cached = _cutDetailsCache[cut.assetGuid];
    setState(() {
      _showSeekPreview = true;
      _seekPreviewGuid = cut.assetGuid;
      _seekPreviewTitle = cut.title.isNotEmpty ? cut.title : 'Loading…';
      _seekPreviewArtist = cut.artist.isNotEmpty ? cut.artist : null;
      if (_isScrubbing) {
        _nowTitle = _seekPreviewTitle;
        _nowArtist = _seekPreviewArtist;
        _nowArtUrl = cached?.artUrl;
        _status = 'Scrub Preview: ${_nowTitle ?? '-'} • ${_nowArtist ?? '-'}';
      }
    });

    if (cut.assetGuid.isNotEmpty &&
        (cut.title.isEmpty && cut.artist.isEmpty) &&
        (_currentChannelId ?? '').isNotEmpty) {
      _maybeFetchCutDetailsForGuid(_currentChannelId!, cut.assetGuid);
    }
  }

  void _maybeFetchCutDetailsForGuid(String channelId, String guid) {
    if (guid.isEmpty) return;
    if (_cutDetailsCache.containsKey(guid)) return;
    if (_cutDetailsFetching.contains(guid)) return;
    _cutDetailsFetching.add(guid);
    () async {
      try {
        final details = await _fetchCutDetails(channelId, guid, cache: true);
        if (!mounted) return;
        if (details == null) return;
        // Update preview if we're still showing it
        if (_showSeekPreview && _seekPreviewGuid == guid) {
          setState(() {
            _seekPreviewTitle =
                details.title.isNotEmpty ? details.title : _seekPreviewTitle;
            _seekPreviewArtist =
                details.artist.isNotEmpty ? details.artist : _seekPreviewArtist;
            if (_isScrubbing) {
              _nowTitle = details.title.isNotEmpty ? details.title : _nowTitle;
              _nowArtist =
                  details.artist.isNotEmpty ? details.artist : _nowArtist;
              _nowArtUrl =
                  details.artUrl.isNotEmpty ? details.artUrl : _nowArtUrl;
              _status =
                  'Scrub Preview: ${_nowTitle ?? '-'} • ${_nowArtist ?? '-'}';
            }
          });
        }
        bool changed = false;
        final List<_NowCut> updated = <_NowCut>[];
        for (final c in _cutMarkers) {
          if (c.assetGuid == guid) {
            updated.add(_NowCut(
              assetGuid: c.assetGuid,
              startMs: c.startMs,
              endMs: c.endMs,
              durationSec: c.durationSec,
              title: details.title,
              artist: details.artist,
            ));
            changed = true;
          } else {
            updated.add(c);
          }
        }
        if (changed) {
          setState(() {
            _cutMarkers = updated;
          });
        }
      } finally {
        _cutDetailsFetching.remove(guid);
      }
    }();
  }

  Future<void> _applyNowPlayingFromGuid(String channelId, String guid) async {
    if (guid.isEmpty) return;
    final cached = _cutDetailsCache[guid];
    if (cached != null) {
      if (!mounted) return;
      setState(() {
        _nowTitle = cached.title.isNotEmpty ? cached.title : _nowTitle;
        _nowArtist = cached.artist.isNotEmpty ? cached.artist : _nowArtist;
        _nowArtUrl = cached.artUrl.isNotEmpty ? cached.artUrl : _nowArtUrl;
        _status = 'Now Playing: ${_nowTitle ?? '-'} • ${_nowArtist ?? '-'}';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _nowTitle = _nowTitle ?? 'Loading…';
      _status = 'Now Playing: ${_nowTitle ?? '-'} • ${_nowArtist ?? '-'}';
    });
    try {
      final details = await _fetchCutDetails(channelId, guid, cache: true);
      if (!mounted) return;
      if (details == null) return;
      setState(() {
        _nowTitle = details.title.isNotEmpty ? details.title : _nowTitle;
        _nowArtist = details.artist.isNotEmpty ? details.artist : _nowArtist;
        _nowArtUrl = details.artUrl.isNotEmpty ? details.artUrl : _nowArtUrl;
        _status = 'Now Playing: ${_nowTitle ?? '-'} • ${_nowArtist ?? '-'}';
      });
    } catch (_) {}
  }

  Future<void> _flashSeekPreviewForCurrentPosition() async {
    try {
      final jsonStr = await _headlessController?.evaluateJavascript(
          source: 'getPosition()');
      if (jsonStr is String && jsonStr.isNotEmpty) {
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;
        final double cur = (map['current'] as num).toDouble();
        _updateSeekPreviewForPlayerSec(cur);
        Future.delayed(const Duration(milliseconds: 1200), () {
          if (!mounted) return;
          setState(() {
            _showSeekPreview = false;
          });
        });
      }
    } catch (_) {}
  }

  Future<void> _deviceChallenge() async {
    final deviceId = widget.appState.deviceId.toString();
    setState(() {
      _busy = true;
      _status = 'GET device challenge...';
    });
    try {
      final resp = await _httpGet(
          '/rest/v3/authentication/device/challenge/$deviceId',
          timeout: const Duration(seconds: 8));
      if (resp.statusCode != 200) {
        setState(() => _status = 'challenge failed: ${resp.statusCode}');
        return;
      }
      logger.d('Streaming API: device challenge response: ${resp.body}');
      final dynamic json = jsonDecode(resp.body);
      final modules =
          json['ModuleListResponse']?['moduleList']?['modules'] as List?;
      if (modules == null || modules.isEmpty) {
        setState(() => _status = 'challenge: no modules');
        final message = json['ModuleListResponse']?['messages']?[0];
        final messageData = message?['message'] as String?;
        final messageCode = message?['code'] as int?;
        if (message != null) {
          setState(() => _status = 'Error: $messageData (code: $messageCode)');
        }
        return;
      }
      final mod = modules.first;
      final challenge = (mod['moduleResponse']?['deviceAuthenticationData']
                  ?['challenge'] ??
              '')
          .toString();
      logger.d(
          'Streaming API: challenge length=${challenge.length} value=${truncate(challenge, max: 256)}');
      if (challenge.isEmpty) {
        setState(() => _status = 'challenge missing');
        return;
      }

      await _sendSxiAuthSequence(challenge);

      _latestChallenge = challenge;
      if (_challengeController.text.isEmpty) {
        _challengeController.text = challenge;
      }

      setState(() => _status =
          'SXi auth sequence scheduled (0ms, +500ms, +1000ms). Waiting indications...');
    } catch (e) {
      logger.e('Streaming API: device challenge error', error: e);
      setState(() => _status = 'challenge error: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _validateDeviceAuth() async {
    final deviceId = widget.appState.deviceId.toString();
    final deviceState = _latestDeviceState;
    final signedChallenge = _latestSignedChallenge;
    if (deviceState == null || signedChallenge == null) {
      setState(() => _status = 'Missing deviceState or signedChallenge');
      return;
    }

    setState(() {
      _busy = true;
      _status = 'POST device validate...';
    });
    try {
      final signedHex = bytesToHex(signedChallenge, upperCase: true);
      final deviceStateHex = bytesToHex(deviceState, upperCase: true);
      final challengeHex = (_latestChallenge ?? '').toLowerCase();
      final body = {
        'moduleList': {
          'modules': [
            {
              'moduleRequest': {
                'signedChallenge': signedHex,
                'deviceState': deviceStateHex,
                'challenge': challengeHex,
                'deviceMode': 'standard'
              }
            }
          ]
        }
      };
      final resp = await _httpPost(
          '/rest/v3/authentication/device/validate/$deviceId', body,
          extraHeaders: {
            if (deviceState.isNotEmpty)
              'X-SiriusXM-deviceState':
                  bytesToHex(deviceState, upperCase: true),
            'X-SiriusXM-deviceMode': 'standard',
          });
      final sc = resp.statusCode;
      if (sc != 200) {
        setState(() => _status = 'validate failed: $sc ${resp.reasonPhrase}');
        return;
      }

      logger.d('Streaming API: response body: ${truncate(resp.body)}');

      // Capture SXM-TOKEN-ID from Set-Cookie
      final headers = resp.headers;
      _updateCookiesFromResponse(headers);
      final setCookie = headers['set-cookie'] ?? headers['Set-Cookie'];
      if (setCookie != null) {
        final token = _parseTokenFromSetCookie(setCookie, 'SXM-TOKEN-ID');
        final masked = token == null
            ? 'null'
            : (token.length <= 8
                ? '***'
                : '${token.substring(0, 4)}...${token.substring(token.length - 4)}');
        logger.i('Streaming API: Set-Cookie present; SXM-TOKEN-ID=$masked');
        setState(() {
          _cookieToken = token;
          if (token != null && token.isNotEmpty) {
            _cookies['SXM-TOKEN-ID'] = token;
          }
          _status = token != null
              ? 'Validated. SXM-TOKEN-ID captured.'
              : 'Validated, but token missing.';
        });
        // Persist token if present
        try {
          if (token != null && token.isNotEmpty) {
            await widget.appState.storageData
                .save(SaveDataType.sxmToken, token);
          }
        } catch (_) {}
        // After token, if we don't have JSESSIONID, call resume again
        if (!_hasCookie('JSESSIONID')) {
          try {
            await _resumeInternal(allowAuthFlow: false);
          } catch (_) {}
        }
        try {
          await _downloadFullLineup();
        } catch (_) {}
      } else {
        logger.w('Streaming API: validate response had no Set-Cookie header');
        setState(() => _status = 'Validated, no Set-Cookie');
      }
    } catch (e) {
      logger.e('Streaming API: validate error', error: e);
      setState(() => _status = 'validate error: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  String? _parseTokenFromSetCookie(String setCookie, String name) {
    try {
      final parts = setCookie.split(',');
      for (final p in parts) {
        final attrs = p.split(';');
        if (attrs.isEmpty) continue;
        final kv = attrs.first.trim();
        final eq = kv.indexOf('=');
        if (eq <= 0) continue;
        final k = kv.substring(0, eq).trim();
        final v = kv.substring(eq + 1).trim();
        if (k == name) return v;
      }
    } catch (_) {}
    return null;
  }

  int? _estimatedServerNowMs() {
    if (_serverWallClockMs <= 0 || _serverWallClockLocalMs <= 0) return null;
    final int localNow = DateTime.now().toUtc().millisecondsSinceEpoch;
    return _serverWallClockMs + (localNow - _serverWallClockLocalMs);
  }

  String _formatHms(int? ms) {
    if (ms == null || ms <= 0) return '-';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  String _fixIsoTz(String iso) {
    // Insert colon before last two TZ digits if ends with "+HHMM" or "-HHMM"
    if (iso.length >= 5) {
      final String tail = iso.substring(iso.length - 5);
      final String sign = tail[0];
      if ((sign == '+' || sign == '-') &&
          int.tryParse(tail.substring(1)) != null) {
        return '${iso.substring(0, iso.length - 5)}$sign${tail.substring(1, 3)}:${tail.substring(3, 5)}';
      }
    }
    return iso;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Streaming Beta'),
      ),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Logged in: ${_cookieToken != null}'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      onPressed: _busy ? null : _runFullAuthFlow,
                      child: const Text('Authorize From Device'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text('Status: $_status', style: theme.textTheme.bodyMedium),
                const SizedBox(height: 12),
                if (_channels.isNotEmpty) ...[
                  TextField(
                    controller: _searchController,
                    onChanged: (value) => setState(() => _searchQuery = value),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search channels by name or number',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      IconButton(
                        onPressed: !_hlsIsPlaying
                            ? null
                            : () async {
                                await _headlessController?.evaluateJavascript(
                                    source: 'seekBy(-15)');
                                await _flashSeekPreviewForCurrentPosition();
                              },
                        icon: const Icon(Icons.fast_rewind),
                        tooltip: 'Rewind 15s',
                      ),
                      IconButton(
                        onPressed: !_hlsIsPlaying
                            ? null
                            : () async {
                                final isPaused = await _headlessController
                                    ?.evaluateJavascript(
                                        source:
                                            "(function(){var v=document.getElementById('v'); if(v.paused){ v.muted=false; v.volume=1.0; v.play(); return true;} v.pause(); return false;})()");
                                setState(() => _isPaused = (isPaused == true));
                              },
                        icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
                        tooltip: 'Play/Pause',
                      ),
                      IconButton(
                        onPressed: !_hlsIsPlaying
                            ? null
                            : () async {
                                await _headlessController?.evaluateJavascript(
                                    source: 'seekBy(15)');
                                await _flashSeekPreviewForCurrentPosition();
                              },
                        icon: const Icon(Icons.fast_forward),
                        tooltip: 'Forward 15s',
                      ),
                      IconButton(
                        onPressed:
                            !_hlsIsPlaying ? null : () => _stopHlsWebView(),
                        icon: const Icon(Icons.stop),
                        tooltip: 'Stop',
                      ),
                      IconButton(
                        onPressed: !_hlsIsPlaying
                            ? null
                            : () async {
                                final res = await _headlessController
                                    ?.evaluateJavascript(
                                        source:
                                            "(function(){ var v=document.getElementById('v'); if(!v) return ''; v.muted = !v.muted; if(!v.muted) v.volume=1.0; return v.muted; })()");
                                setState(() {
                                  _isMuted = (res == true);
                                  _status =
                                      _isMuted ? 'HLS muted' : 'HLS unmuted';
                                });
                              },
                        icon:
                            Icon(_isMuted ? Icons.volume_off : Icons.volume_up),
                        tooltip: 'Mute/Unmute',
                      ),
                      IconButton(
                        onPressed: !_hlsIsPlaying
                            ? null
                            : () async {
                                await _headlessController?.evaluateJavascript(
                                    source: 'goLive()');
                              },
                        icon: const Icon(Icons.sensors),
                        tooltip: 'Go Live',
                      ),
                      const SizedBox(width: 8),
                      if (_lastHlsUrl != null)
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(
                                child: Slider(
                                  min: 0,
                                  max: 1,
                                  value: _isScrubbing
                                      ? _scrubValue
                                      : (_posEnd > _posStart &&
                                              _posCurrent >= _posStart)
                                          ? (((_posCurrent - _posStart) /
                                                  (_posEnd - _posStart))
                                              .clamp(0.0, 1.0))
                                          : 0,
                                  onChanged: !_hlsIsPlaying
                                      ? null
                                      : (p) {
                                          final start = _posStart;
                                          final end = _posEnd;
                                          if (end > start) {
                                            final target =
                                                start + (end - start) * p;
                                            _pendingSeekTargetSec = target;
                                            setState(() {
                                              _isScrubbing = true;
                                              _scrubValue = p;
                                              _showSeekPreview = true;
                                            });
                                            _updateSeekPreviewForPlayerSec(
                                                target);
                                          }
                                        },
                                  onChangeStart: !_hlsIsPlaying
                                      ? null
                                      : (p) {
                                          _pendingSeekTargetSec = null;
                                          setState(() {
                                            _showSeekPreview = true;
                                            _isScrubbing = true;
                                            _scrubValue = p;
                                          });
                                          if (_cutMarkers.length < 8) {
                                            () async {
                                              try {
                                                await _fetchNowPlaying();
                                              } catch (_) {}
                                            }();
                                          }
                                        },
                                  onChangeEnd: !_hlsIsPlaying
                                      ? null
                                      : (p) async {
                                          final start = _posStart;
                                          final end = _posEnd;
                                          double? target =
                                              _pendingSeekTargetSec;
                                          if (target == null && end > start) {
                                            target = start + (end - start) * p;
                                          }
                                          final String channelId =
                                              (_currentChannelId ?? '').trim();
                                          final String? previewGuid =
                                              (_seekPreviewGuid ?? '')
                                                      .isNotEmpty
                                                  ? _seekPreviewGuid
                                                  : null;
                                          // Commit the seek on release
                                          if (target != null) {
                                            try {
                                              await _headlessController
                                                  ?.evaluateJavascript(
                                                      source:
                                                          'seekTo(${target.toStringAsFixed(2)})');
                                            } catch (_) {}
                                          }

                                          if (channelId.isNotEmpty &&
                                              previewGuid != null) {
                                            try {
                                              await _applyNowPlayingFromGuid(
                                                  channelId, previewGuid);
                                            } catch (_) {}
                                          }

                                          Future.delayed(
                                              const Duration(milliseconds: 800),
                                              () {
                                            if (!mounted) return;
                                            setState(() {
                                              _showSeekPreview = false;
                                              _isScrubbing = false;
                                            });
                                          });

                                          try {
                                            _seekNowPlayingDebounce?.cancel();
                                          } catch (_) {}
                                          _seekNowPlayingDebounce = Timer(
                                              const Duration(milliseconds: 350),
                                              () async {
                                            if (!mounted) return;
                                            if (!_hlsIsPlaying) return;
                                            try {
                                              final jsonStr =
                                                  await _headlessController
                                                      ?.evaluateJavascript(
                                                          source:
                                                              'getPosition()');
                                              if (jsonStr is String &&
                                                  jsonStr.isNotEmpty) {
                                                final map = jsonDecode(jsonStr)
                                                    as Map<String, dynamic>;
                                                if (!mounted) return;
                                                setState(() {
                                                  _posStart =
                                                      (map['start'] as num)
                                                          .toDouble();
                                                  _posEnd = (map['end'] as num)
                                                      .toDouble();
                                                  _posCurrent =
                                                      (map['current'] as num)
                                                          .toDouble();
                                                });
                                              }
                                            } catch (_) {}
                                            try {
                                              await _fetchNowPlaying();
                                            } catch (_) {}
                                          });
                                        },
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  if (_showSeekPreview && (_seekPreviewGuid ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(
                          top: 4.0, left: 8.0, right: 8.0),
                      child: Row(
                        children: [
                          const Icon(Icons.music_note, size: 16),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              [
                                (_seekPreviewTitle ?? 'Loading…'),
                                if ((_seekPreviewArtist ?? '').isNotEmpty)
                                  '• ${_seekPreviewArtist!}',
                              ].join(' '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  if (_nowTitle != null ||
                      _nowArtist != null ||
                      _nowArtUrl != null)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if ((_nowArtUrl ?? '').isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(right: 8.0),
                            child: Image.network(_nowArtUrl!,
                                width: 48, height: 48, fit: BoxFit.cover),
                          ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_nowTitle ?? '-',
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              Text(_nowArtist ?? '-',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall),
                            ],
                          ),
                        ),
                      ],
                    ),
                  Builder(builder: (context) {
                    final int? nowMs = _timelineNowOverrideMs > 0
                        ? _timelineNowOverrideMs
                        : _estimatedServerNowMs();
                    final int? nextMs =
                        _nextCutEndMs > 0 ? _nextCutEndMs : null;
                    String delta = '';
                    if (nowMs != null && nextMs != null) {
                      final remMs = nextMs - nowMs;
                      final secs = (remMs / 1000).ceil();
                      delta = secs >= 0 ? ' (T-$secs s)' : ' (T+${-secs} s)';
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 6.0, bottom: 2.0),
                      child: Row(
                        children: [
                          const Icon(Icons.schedule, size: 14),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Now: ${_formatHms(nowMs)}   Next: ${_formatHms(nextMs)}$delta',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                  // HLS.js current fragment PDT window
                  if (_hlsFragEndMs > 0)
                    Builder(builder: (context) {
                      final int nowMs = _estimatedServerNowMs() ??
                          DateTime.now().toUtc().millisecondsSinceEpoch;
                      final String deltaSec = _hlsFragEndMs > 0
                          ? '${((_hlsFragEndMs - nowMs) ~/ 1000)}'
                          : '-';
                      return Padding(
                        padding: const EdgeInsets.only(
                            top: 2.0, left: 20.0, bottom: 6.0),
                        child: Row(
                          children: [
                            const Icon(Icons.music_note, size: 14),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'HLS frag: #$_hlsFragSn ${_formatHms(_hlsFragStartMs)} -> ${_formatHms(_hlsFragEndMs)} (≈${(_hlsFragDurMs / 1000).toStringAsFixed(0)}s)  Δ=${deltaSec}s',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          setState(
                              () => _status = 'Manual now-playing fetch...');
                          try {
                            await _fetchNowPlaying();
                          } catch (_) {}
                        },
                        icon: const Icon(Icons.refresh),
                        label: const Text('Refresh Now-Playing'),
                      ),
                      const SizedBox(width: 12),
                      const Text('Volume'),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Slider(
                          min: 0,
                          max: 1,
                          divisions: 20,
                          value: _volume,
                          onChanged: !_hlsIsPlaying
                              ? null
                              : (v) async {
                                  setState(() => _volume = v);
                                  await _headlessController?.evaluateJavascript(
                                      source:
                                          'setVolume(${v.toStringAsFixed(2)})');
                                },
                        ),
                      ),
                    ],
                  ),
                  Text('Channels (${_channels.length})',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _filteredChannels.length,
                      itemBuilder: (context, index) {
                        final ch = _filteredChannels[index];
                        final logoBytes = _logoCache[ch.channelId];
                        if (logoBytes == null) {
                          _maybeFetchLogo(ch);
                        }
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          leading: SizedBox(
                            width: 80,
                            child: logoBytes == null
                                ? _buildChannelLogoPlaceholder(ch)
                                : Image.memory(
                                    logoBytes,
                                    cacheHeight: 128,
                                    fit: BoxFit.contain,
                                    gaplessPlayback: true,
                                    filterQuality: FilterQuality.medium,
                                  ),
                          ),
                          title: Text('Channel ${ch.channelNumber}'),
                          subtitle: Text(ch.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () async {
                            setState(
                                () => _status = 'Resuming ${ch.channelId}...');
                            try {
                              await _resumeInternal(
                                allowAuthFlow: false,
                                channelId: ch.channelId,
                                contentType: 'live',
                              );
                              if ((_lastHlsUrl ?? '').isEmpty) {
                                final mref = (ch.mref ?? '').trim();
                                logger.i(
                                    'Tune fallback: no HLS from resume; channelId=${ch.channelId} mref=${mref.isEmpty ? '<missing>' : mref}');
                                if (mref.isNotEmpty) {
                                  await _tuneNowPlayingLiveByMref(mref);
                                } else {
                                  await _tuneNowPlayingLiveByChannelId(
                                      ch.channelId);
                                }
                              }
                            } catch (e) {
                              setState(() => _status = 'Resume error: $e');
                            }
                          },
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          // No inline WebView, playback is headless
        ],
      ),
    );
  }
}

// Temporary channel model for selector UI
class _StreamChannel {
  final String channelId;
  final String name;
  final String channelNumber;
  final String? mref;
  final String? logoUrl;

  const _StreamChannel({
    required this.channelId,
    required this.name,
    required this.channelNumber,
    this.mref,
    this.logoUrl,
  });
}

class _NowCut {
  final String assetGuid;
  final int startMs;
  final int endMs;
  final double durationSec;
  final String title;
  final String artist;
  const _NowCut({
    required this.assetGuid,
    required this.startMs,
    required this.endMs,
    required this.durationSec,
    required this.title,
    required this.artist,
  });
}

class _CutDetails {
  final String title;
  final String artist;
  final String artUrl;
  const _CutDetails(
      {required this.title, required this.artist, required this.artUrl});
}
