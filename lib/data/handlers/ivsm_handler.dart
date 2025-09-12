// Handles In-Vehicle Subscription Messaging data
import 'dart:io';
import 'dart:convert';
import 'package:orbit/data/data_handler.dart';
import 'package:orbit/sxi_indication_types.dart';
import 'package:orbit/data/access_unit.dart';
import 'package:orbit/data/bit_buffer.dart';
import 'package:orbit/sxi_layer.dart';
import 'package:orbit/logging.dart';
import 'package:orbit/crc.dart';

// IVSM helper enums
class IvsmSubsType {
  static const int audio = 0;
  static const int data = 1;
  static const int all = 2;
}

class IvsmTxtParamTag {
  static const int ipUrl = 0;
  static const int pagUrl = 1;
}

class IvsmIntParamTag {
  static const int remindMeLaterDelay = 0;
  static const int defaultTuneSid = 1;
}

class IvsmMtype {
  static const int undefined = 0;
  static const int trialWelcome = 1;
  static const int endOfTrial = 2;
  static const int winbackGAWB = 4;
  static const int fta = 8;
  static const int selfActivateTrial = 16;
  static const int selfPayOnboarding = 32;
  static const int selfPayEngagement = 64;
  static const int selfPayNonPay = 128;
  static const int specialOffer = 256;
  static const int selfPay = 512;
  static const int unsupported = 32768;
}

class IvsmMessageDisplayType {
  static const int subsNotification = 0;
  static const int oneTouch = 1;
}

class IvsmAckType {
  static const int normal = 0;
  static const int hide = 1;
  static const int none = 2;
}

// IVSM Handler
class IVSMHandler extends DSIHandler {
  IVSMHandler(SXiLayer sxiLayer) : super(DataServiceIdentifier.ivsm, sxiLayer);

  int? _debugIvsmPrefix20;
  int? _debugIvsmSuffix16;
  int? _debugSubscriptionType;
  int? _debugNowDays;

  void setDebugIvsmId({required int prefix20, required int suffix16}) {
    _debugIvsmPrefix20 = prefix20 & 0xFFFFF;
    _debugIvsmSuffix16 = suffix16 & 0xFFFF;
  }

  void setDebugSubscriptionType(int subType) {
    _debugSubscriptionType = subType & 0xFF;
  }

  void setDebugNowDays(int days) {
    _debugNowDays = days;
  }

  final Map<int, _AudioClipEntry> _clipEntries = <int, _AudioClipEntry>{};
  _AudioClipEntry? _audioLogo;
  // Track last parsed rows and current message for ACK handling
  List<_RecipeRow> _lastRowsMain = <_RecipeRow>[];
  List<_RecipeRow> _lastRowsFta = <_RecipeRow>[];
  final Map<int, _RecipeRow> _msgUidToRow = <int, _RecipeRow>{};
  // Parsed configuration storage
  int? _cfgRemindMeLaterDelay;
  int? _cfgDefaultTuneSid;
  String? _cfgIpUrl;
  String? _cfgPagUrl;
  int? _lastConfigSignature;

  @override
  void onAccessUnitComplete(AccessUnit unit) {
    final List<int> auBytes = unit.getHeaderAndData();
    BitBuffer bitBuffer = BitBuffer(auBytes);
    int pvn = bitBuffer.readBits(4);
    int carid = bitBuffer.readBits(3);

    if (pvn == 1) {
      try {
        if (!CRC32.check(auBytes, unit.crc)) {
          logger.e('IVSMHandler: CRC check failed for AU (CARID $carid)');
          return;
        }
      } catch (_) {
        logger.e('IVSMHandler: CRC check failed (exception)');
        return;
      }

      switch (carid) {
        case 0:
          logger.d('IVSMHandler: Radio Assignment Carousel');
          _handleRadioAssignmentCarousel(bitBuffer, auBytes);
          break;
        case 1:
          logger.d('IVSMHandler: Recipe Carousel');
          _handleRecipeCarousel(bitBuffer);
          break;
        case 2:
          logger.d('IVSMHandler: Audio Clip Carousel');
          _handleAudioClipCarousel(bitBuffer);
          break;
        case 3:
          logger.d('IVSMHandler: Configuration Carousel');
          _handleConfigurationCarousel(bitBuffer);
          break;
      }
    } else {
      logger.w("IVSMHandler: Invalid Version: $pvn");
    }
  }

  void _handleRadioAssignmentCarousel(BitBuffer b, List<int> baseBytes) {
    // Read 16-bit signature, then 1-bit type flag
    final int assignmentSignature = b.readBits(16);
    final int isHideFlagsAssignment = b.readBits(1);

    logger.t('IVSMHandler: Assignment AU (Signature: $assignmentSignature)');

    if (b.hasError) {
      logger.w(
          'IVSMHandler: Radio Assignment: bitbuffer error while reading header');
      return;
    }

    if (isHideFlagsAssignment == 1) {
      logger.d('IVSMHandler: HIDE FLAGS ASSIGNMENT');
      _handleHideFlagsAssignment(b, assignmentSignature, baseBytes);
    } else {
      logger.d('IVSMHandler: RECIPE ASSIGNMENT');
      _handleRecipeAssignment(b, assignmentSignature, baseBytes);
    }
  }

  void _handleHideFlagsAssignment(
      BitBuffer b, int signature, List<int> baseBytes) {
    // Parse 10-bit mask and optional extended 10-bit mask
    final int hideFlagsLo10 = b.readBits(10);
    int hideFlags = hideFlagsLo10 & 0x3FF;
    final int extPresent = b.readBits(1);
    if (extPresent == 1) {
      final int hideFlagsHi10 = b.readBits(10) & 0x3FF;
      hideFlags |= (hideFlagsHi10 << 10);
    }

    logger.d(
        'IVSMHandler: Hide Flags Assignment: signature=$signature mask=0x${hideFlags.toRadixString(16).toUpperCase()}');

    if (b.hasError) {
      logger.w('IVSMHandler: HideFlags: bitbuffer error while reading mask');
      return;
    }

    final _IvsmIdIndex? idx = _parseIvsmIdIndex(b, baseBytes);
    if (idx == null) {
      logger.w('IVSMHandler: HideFlags: failed to parse IVSM ID index');
      return;
    }
    logger.t(
        'IVSMHandler: HideFlags: IVSM ID index parsed: prefixes=${idx.entries.length}');

    _dumpIvsmIndex(idx, context: 'HideFlags');

    final (_IvsmIdPair?, String) deviceId = _getDeviceIvsmIdPairOrLog();
    final int? pref = _debugIvsmPrefix20 ?? deviceId.$1?.prefix20;
    final int? sfx = _debugIvsmSuffix16 ?? deviceId.$1?.suffix16;
    if (pref != null && sfx != null) {
      final int code = _checkIvsmId(idx, pref, sfx);
      logger.t(
          'IVSMHandler: HideFlags: match result code=$code${deviceId.$1 != null ? ' using ${deviceId.$2}' : ' using debug'}');
      if (code == 0) {
        logger.i(
            'IVSMHandler: HideFlags: MATCH (would apply mask=0x${hideFlags.toRadixString(16).toUpperCase()})');
      } else {
        logger.t('IVSMHandler: HideFlags: no match; no-op');
      }
    } else {
      logger.t('IVSMHandler: HideFlags: no device IVSM ID available');
    }
  }

  void _handleRecipeAssignment(
      BitBuffer b, int signature, List<int> baseBytes) {
    final _IvsmAssignmentInfo info = _readIvsmAssignmentInfo(b);
    if (b.hasError) {
      logger.w(
          'IVSMHandler: Recipe: bitbuffer error while reading assignment info');
      return;
    }

    logger.d(
        'IVSMHandler: Recipe Assignment: signature=$signature mainId=${info.mainRecipeId?.toString() ?? 'n/a'} ftaId=${info.ftaRecipeId?.toString() ?? 'n/a'} dataId=${info.dataRecipeId?.toString() ?? 'n/a'} dtA=${info.dayA?.toString() ?? 'n/a'} dtB=${info.dayB?.toString() ?? 'n/a'} resetHide=${info.resetHideFlags ? '1' : '0'}');

    final _IvsmIdIndex? idx = _parseIvsmIdIndex(b, baseBytes);
    if (idx == null) {
      logger.w('IVSMHandler: Recipe: failed to parse IVSM ID index');
      return;
    }
    logger.t(
        'IVSMHandler: Recipe: IVSM ID index parsed: prefixes=${idx.entries.length}');

    _dumpIvsmIndex(idx, context: 'RecipeAssign');

    final (_IvsmIdPair?, String) deviceId = _getDeviceIvsmIdPairOrLog();
    final int? pref = _debugIvsmPrefix20 ?? deviceId.$1?.prefix20;
    final int? sfx = _debugIvsmSuffix16 ?? deviceId.$1?.suffix16;
    if (pref != null && sfx != null) {
      final int code = _checkIvsmId(idx, pref, sfx);
      logger.t(
          'IVSMHandler: Recipe: match result code=$code${deviceId.$1 != null ? ' using ${deviceId.$2}' : ' using debug'}');
      if (code == 0) {
        logger.i(
            'IVSMHandler: Recipe: MATCH (would assign main=${info.mainRecipeId?.toString() ?? 'n/a'} fta=${info.ftaRecipeId?.toString() ?? 'n/a'}${info.resetHideFlags ? ' and reset hide' : ''})');
      } else {
        logger.t('IVSMHandler: Recipe: no match; no-op');
      }
    } else {
      logger.t('IVSMHandler: Recipe: no device IVSM ID available');
    }
  }

  _IvsmAssignmentInfo _readIvsmAssignmentInfo(BitBuffer b) {
    int? mainId;
    int? ftaId;
    int? dataId;
    int? dayA;
    int? dayB;
    bool resetHide = false;

    if (b.readBits(1) == 1) {
      mainId = b.readBits(9);
    }
    if (b.readBits(1) == 1) {
      ftaId = b.readBits(9);
    }
    if (b.readBits(1) == 1) {
      dataId = b.readBits(9);
    }
    if (b.readBits(1) == 1) {
      dayA = b.readBits(14);
    }
    if (b.readBits(1) == 1) {
      dayB = b.readBits(14);
    }
    resetHide = b.readBits(1) == 1;

    return _IvsmAssignmentInfo(
      mainRecipeId: mainId,
      ftaRecipeId: ftaId,
      dataRecipeId: dataId,
      dayA: dayA,
      dayB: dayB,
      resetHideFlags: resetHide,
    );
  }

  _IvsmIdIndex? _parseIvsmIdIndex(BitBuffer b, List<int> baseBytes) {
    final int dcount = b.readBits(8) + 1;
    if (b.hasError) return null;

    final List<_IvsmPrefixEntry> entries = <_IvsmPrefixEntry>[];
    for (int i = 0; i < dcount; i++) {
      final int prefix20 = b.readBits(20);
      if (b.hasError) return null;

      final int treeFlag = b.readBits(1);
      final int count = b.readBits(4) + 1;
      final int offOrSuffix = b.readBits(16);
      if (b.hasError) return null;

      final _IvsmPrefixEntry entry = _IvsmPrefixEntry(
        prefix20: prefix20,
        isTree: treeFlag == 1,
        count: count,
        offsetOrSuffix: offOrSuffix,
      );

      if (entry.isTree) {
        final BitBuffer sub = _subBuffer(baseBytes, offOrSuffix);
        entry.upperList = _parseUpperListWithLower(sub, count);
      } else if (count == 1) {
        entry.singleSuffix = offOrSuffix & 0xFFFF;
      } else {
        final BitBuffer sub = _subBuffer(baseBytes, offOrSuffix);
        entry.suffixList = _parseSuffixList(sub, count);
      }

      entries.add(entry);
    }

    return _IvsmIdIndex(entries: entries);
  }

  BitBuffer _subBuffer(List<int> base, int byteOffset) {
    if (byteOffset < 0 || byteOffset >= base.length) {
      return BitBuffer(const <int>[]);
    }
    final List<int> sub = base.sublist(byteOffset);
    return BitBuffer(sub);
  }

  List<_IvsmUpperEntry> _parseUpperListWithLower(BitBuffer b, int count) {
    final List<_IvsmUpperEntry> list = <_IvsmUpperEntry>[];
    int? lastUpper;
    for (int i = 0; i < count; i++) {
      final int upper4 = b.readBits(4) & 0xF;
      if (b.hasError) break;
      if (lastUpper != null && upper4 < lastUpper) {
        // order warning; continue
      }
      lastUpper = upper4;

      final _IvsmLowerData lower = _parseLowerData(b);
      list.add(_IvsmUpperEntry(upperNibble: upper4, lowerData: lower));
    }
    return list;
  }

  _IvsmLowerData _parseLowerData(BitBuffer b) {
    final int isMidLeaf = b.readBits(1);
    final int count = b.readBits(8) + 1;
    if (isMidLeaf == 1) {
      final List<_IvsmMidEntry> mids = <_IvsmMidEntry>[];
      for (int i = 0; i < count; i++) {
        final int mid8 = b.readBits(8) & 0xFF;
        if (b.hasError) break;
        final _IvsmLeafCondition leaf = _parseLeafCondition(b);
        mids.add(_IvsmMidEntry(mid8: mid8, leaf: leaf));
      }
      return _IvsmLowerData.midLeaf(mids);
    } else {
      final List<int> lowers = <int>[];
      for (int i = 0; i < count; i++) {
        final int lower12 = b.readBits(12) & 0xFFF;
        if (b.hasError) break;
        lowers.add(lower12);
      }
      return _IvsmLowerData.lowerList(lowers);
    }
  }

  _IvsmLeafCondition _parseLeafCondition(BitBuffer b) {
    final int flag = b.readBits(1);
    if (flag == 1) {
      final int mask16 = b.readBits(16) & 0xFFFF;
      return _IvsmLeafCondition.bitmask(mask16);
    }
    final int leaf4 = b.readBits(4) & 0xF;
    return _IvsmLeafCondition.single(leaf4);
  }

  List<int> _parseSuffixList(BitBuffer b, int count) {
    final List<int> list = <int>[];
    int? last;
    for (int i = 0; i < count; i++) {
      final int sfx = b.readBits(16) & 0xFFFF;
      if (b.hasError) break;
      if (last != null && sfx <= last) {
        // order warning; continue
      }
      last = sfx;
      list.add(sfx);
    }
    return list;
  }

  void _dumpIvsmIndex(_IvsmIdIndex index, {required String context}) {
    // Dump device-derived Radio ID preview
    final (_IvsmIdPair?, String) deviceId = _getDeviceIvsmIdPairOrLog();
    final int? dp = _debugIvsmPrefix20 ?? deviceId.$1?.prefix20;
    final int? ds = _debugIvsmSuffix16 ?? deviceId.$1?.suffix16;
    if (dp != null && ds != null) {
      logger.i(
          'IVSMHandler: [$context] Device IVSM ID: prefix=0x${dp.toRadixString(16).padLeft(5, '0')} suffix=0x${ds.toRadixString(16).padLeft(4, '0')} (${deviceId.$2})');
    }

    int pidx = 0;
    for (final _IvsmPrefixEntry pe in index.entries) {
      final String head =
          'IVSMHandler: [$context] PREFIX[$pidx]=0x${pe.prefix20.toRadixString(16).padLeft(5, '0')}${pe.isTree ? ' TREE' : ' LIST'} count=${pe.count}';
      logger.i(head);
      if (pe.isTree) {
        if (pe.upperList != null) {
          int uidx = 0;
          for (final _IvsmUpperEntry ue in pe.upperList!) {
            logger.i(
                '  UPPER[$uidx]=0x${ue.upperNibble.toRadixString(16).padLeft(1, '0')}');
            _dumpLowerData(ue.lowerData, indent: '    ');
            uidx++;
          }
        }
      } else {
        if (pe.count == 1 && pe.singleSuffix != null) {
          logger.i(
              '  SUFFIX=0x${pe.singleSuffix!.toRadixString(16).padLeft(4, '0')}');
        } else if (pe.suffixList != null) {
          final String list = pe.suffixList!
              .map((s) => '0x${s.toRadixString(16).padLeft(4, '0')}')
              .join(', ');
          logger.i('  SUFFIX_LIST[${pe.suffixList!.length}]=[$list]');
        }
      }
      pidx++;
    }
  }

  void _dumpLowerData(_IvsmLowerData data, {required String indent}) {
    if (data.lowers != null) {
      final String list = data.lowers!
          .map((v) => '0x${v.toRadixString(16).padLeft(3, '0')}')
          .join(', ');
      logger.i('${indent}LOWER_LIST[${data.lowers!.length}]=[$list]');
      return;
    }
    if (data.mids != null) {
      int midx = 0;
      for (final _IvsmMidEntry me in data.mids!) {
        logger.i(
            '${indent}MID[$midx]=0x${me.mid8.toRadixString(16).padLeft(2, '0')}');
        _dumpLeaf(me.leaf, indent: '$indent  ');
        midx++;
      }
    }
  }

  void _dumpLeaf(_IvsmLeafCondition leaf, {required String indent}) {
    if (leaf.singleLeaf4 != null) {
      logger.i(
          '${indent}LEAF=0x${leaf.singleLeaf4!.toRadixString(16).padLeft(1, '0')}');
      return;
    }
    if (leaf.bitmask16 != null) {
      final int mask = leaf.bitmask16! & 0xFFFF;
      final List<String> bits = <String>[];
      for (int i = 0; i < 16; i++) {
        if (((mask >> i) & 1) != 0) bits.add('0x${i.toRadixString(16)}');
      }
      logger.i(
          '${indent}LEAF_MASK=0x${mask.toRadixString(16).padLeft(4, '0')} -> [${bits.join(', ')}]');
    }
  }

  // Return 0 if row's subscription type matches the device's subscription (or device is wildcard 2)
  int _processSubscriptionType(int rowSubscriptionType) {
    final int deviceSub = (_debugSubscriptionType ?? IvsmSubsType.all) & 0xFF;
    if (deviceSub == IvsmSubsType.all ||
        deviceSub == (rowSubscriptionType & 0xFF)) {
      logger.t(
          'IVSMHandler: SubscriptionType OK (device=$deviceSub, row=$rowSubscriptionType)');
      return 0;
    }
    logger.t(
        'IVSMHandler: SubscriptionType mismatch (device=$deviceSub, row=$rowSubscriptionType), skipping row');
    return 1;
  }

  void _handleRecipeCarousel(BitBuffer b) {
    // First 9 bits RecipeID, then 16-bit Signature, then zlib CSV body
    if (b.viewRemainingData.isEmpty) {
      logger.t('IVSMHandler: Recipe Carousel empty');
      return;
    }

    final int recipeId = b.readBits(9);
    final int signature = b.readBits(16);

    if (signature == 0) {
      logger.w('IVSMHandler: RECIPE SIGNATURE = 0 (Recipe ID: $recipeId)');
    }

    logger.t(
        'IVSMHandler: Recipe AU (Recipe ID: $recipeId, Signature: $signature)');

    // Remaining should be zlib-compressed CSV text
    b.align();
    final List<int> compressed = b.remainingData;
    if (compressed.isEmpty) {
      logger.w('IVSMHandler: Recipe AU has no body');
      return;
    }

    final int zres = _checkZlibFlagsBytes(compressed);
    if (zres != 0) {
      logger.w('IVSMHandler: Recipe zlib header invalid (code $zres)');
      return;
    }

    try {
      final List<int> raw = ZLibDecoder().convert(compressed);
      final String text = utf8.decode(raw, allowMalformed: true);
      final int lineCount =
          '\n'.allMatches(text).length + (text.isNotEmpty ? 1 : 0);
      logger.i(
          'IVSMHandler: Recipe decompressed: ${raw.length} bytes, lines=$lineCount');

      // Preview first 2 lines
      final List<String> lines = text.split('\n');
      for (int i = 0; i < lines.length && i < 10; i++) {
        final String ln = lines[i];
        logger.t(
            'IVSMHandler: CSV[$i]: ${ln.length <= 200 ? ln : ('${ln.substring(0, 200)} …')}');
      }

      _parseRecipeCsvAndProcess(recipeId, signature, text);
    } catch (e) {
      logger.w('IVSMHandler: Recipe decompression failed: $e');
    }
  }

  // Returns 0 on OK, 2 on read error, 11 (0xB) on invalid value
  int _checkZlibFlagsBytes(List<int> bytes) {
    if (bytes.length < 2) return 2;
    final int cmf = bytes[0] & 0xFF; // Compression method/flags
    if (cmf != 0x78) {
      logger.w("IVSMHandler: ZLIB CMF invalid: 0x${cmf.toRadixString(16)}");
      return 11;
    }
    final int flg = bytes[1] & 0xFF;
    if (flg != 0xDA && flg != 0x9C && flg != 0x01) {
      // Allow common zlib flags (default 0xDA, fastest 0x9C, no compression 0x01)
      logger.w('IVSMHandler: ZLIB FLG unusual: 0x${flg.toRadixString(16)}');
      // Still allow, return success to attempt decompression
      return 0;
    }
    return 0;
  }

  // Trigger eval helper (A/O within window, D immediate)
  // Returns 0 if current, 3 if passed, 1 if unsupported, 2 on error
  int _processTriggerByte(int triggerByte,
      {required int startDay, required int endDay}) {
    // Normalize days
    final int nowDays = _debugNowDays ??
        DateTime.now().toUtc().millisecondsSinceEpoch ~/
            const Duration(days: 1).inMilliseconds;
    if (triggerByte == 0x44) {
      // 'D' (DO)
      logger.t("IVSMHandler: Trigger 'DO' -> current");
      return 0;
    }
    if (triggerByte == 0x41 || triggerByte == 0x4F) {
      // 'A' or 'O'
      if (endDay < nowDays) {
        logger
            .t('IVSMHandler: Trigger window passed: end=$endDay now=$nowDays');
        return 3;
      }
      if (startDay <= nowDays) {
        logger.t(
            'IVSMHandler: Trigger window current: start=$startDay now=$nowDays end=$endDay');
        return 0;
      }
      logger.t(
          'IVSMHandler: Trigger window not yet arrived: start=$startDay now=$nowDays');
      return 2; // Not yet
    }
    logger.t(
        'IVSMHandler: Unsupported trigger: 0x${triggerByte.toRadixString(16)}');
    return 1;
  }

  _AudioClipFormatResult _readAudioClipFormat(BitBuffer b, int maxBytes) {
    // Read 16-bit header length
    final int headerLen = b.readBits(16);
    final int encoder = b.readBits(8); // Should be 6
    final int eventByte = b.readBits(8);
    final int audioBytes = b.readBits(16);

    final int bitsToSkip = (headerLen << 3) - 0x30; // 48 bits already read
    if (bitsToSkip > 0) {
      b.skipBits(bitsToSkip);
    }

    if (b.hasError) {
      logger.w('IVSMHandler: readAudioClipFormat: failed to read header');
      return const _AudioClipFormatResult(
          ok: false, errorCode: 2, encoder: 0, eventByte: 0, bytes: <int>[]);
    }

    if (audioBytes == 0) {
      logger.w('IVSMHandler: readAudioClipFormat: Number of Audio Bytes = 0');
      return const _AudioClipFormatResult(
          ok: false, errorCode: 2, encoder: 0, eventByte: 0, bytes: <int>[]);
    }

    logger.t('IVSMHandler: readAudioClipFormat: bytes=$audioBytes');

    if (audioBytes > maxBytes) {
      logger.w(
          'IVSMHandler: readAudioClipFormat: size $audioBytes > max $maxBytes');
      return const _AudioClipFormatResult(
          ok: false, errorCode: 11, encoder: 0, eventByte: 0, bytes: <int>[]);
    }

    // Validate actual payload length equals audioBytes
    final int avail = b.remainingBytes;
    if (avail != audioBytes) {
      logger.w(
          'IVSMHandler: readAudioClipFormat: insufficient data: avail=$avail expected=$audioBytes');
      return const _AudioClipFormatResult(
          ok: false, errorCode: 11, encoder: 0, eventByte: 0, bytes: <int>[]);
    }

    if (encoder != 6) {
      logger.w(
          'IVSMHandler: readAudioClipFormat: unsupported encoder=$encoder expected=6');
      return const _AudioClipFormatResult(
          ok: false, errorCode: 11, encoder: 0, eventByte: 0, bytes: <int>[]);
    }

    // Read the audio data bytes
    final List<int> data = b.readBytes(audioBytes);
    return _AudioClipFormatResult(
        ok: true,
        errorCode: 0,
        encoder: encoder,
        eventByte: eventByte,
        bytes: data);
  }

  void _updateClipsCollection(_ClipSlot slot) {
    // Ensure a clip entry exists for the clipId referenced by recipe rows
    final _AudioClipEntry? clip =
        slot.clipId == 0 ? _audioLogo : _clipEntries[slot.clipId];
    if (clip == null) {
      logger.t('IVSMHandler: Clip ${slot.clipId} referenced but not present');
      return;
    }
    logger.t(
        'IVSMHandler: Clip collection update: id=${slot.clipId} mtype=${slot.recipeType} event=${String.fromCharCode(slot.eventByte)} epoch=${slot.epoch}');
  }

  void _parseRecipeCsvAndProcess(int recipeId, int signature, String csv) {
    final List<String> lines =
        csv.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) {
      logger.w('IVSMHandler: CSV empty after split');
      return;
    }
    final Map<String, int> hdr = _parseCsvHeader(lines.first);
    if (hdr.isEmpty) {
      logger.w('IVSMHandler: CSV header not recognized');
      return;
    }
    final List<_RecipeRow> rows = <_RecipeRow>[];
    for (int i = 1; i < lines.length; i++) {
      final List<String> cols = _splitCsvLine(lines[i]);
      if (cols.isEmpty) continue;
      final _RecipeRow? row = _parseRecipeRow(cols, hdr);
      if (row != null) rows.add(row);
    }
    logger.i('IVSMHandler: CSV parsed rows=${rows.length}');

    final Iterable<_RecipeRow> mainRows = rows.where((r) => r.mtype == 1);
    final Iterable<_RecipeRow> ftaRows = rows.where((r) => r.mtype == 2);

    void processGroup(String name, Iterable<_RecipeRow> group) {
      logger.t('IVSMHandler: Process $name rows (${group.length})');
      int idx = 0;
      for (final _RecipeRow row in group) {
        idx++;
        final int pre = _preprocessRow(row);
        if (pre == 1) {
          continue; // Sub/trigger unsupported
        }
        if (pre == 2) {
          continue; // Timeframe not yet
        }
        if (pre == 3) {
          continue; // Timeframe passed
        }
        switch (row.eventCode) {
          case 'G':
            _handleSaveFlags(row);
            break;
          case 'N':
            _handleNullEvent(row);
            break;
          case 'P':
            _handlePlayEvent(name, row);
            break;
          case 'S':
            _handleSwitchMainRecipe(row);
            break;
          default:
            logger.t('IVSMHandler: Unknown event ${row.eventCode} at row $idx');
            break;
        }
      }
    }

    _lastRowsMain = mainRows.toList(growable: false);
    _lastRowsFta = ftaRows.toList(growable: false);
    processGroup('MAIN', _lastRowsMain);
    processGroup('FTA', _lastRowsFta);
  }

  int _preprocessRow(_RecipeRow row) {
    if (_processSubscriptionType(row.subType) != 0) {
      return 1;
    }
    final int trigByte = _triggerCharToByte(row.trigger);
    final int t = _processTriggerByte(trigByte,
        startDay: row.startDay, endDay: row.endDay);
    return t;
  }

  int _triggerCharToByte(String ch) {
    if (ch.isEmpty) return 0;
    final int c = ch.codeUnitAt(0) & 0xFF;
    return c;
  }

  void _handleSaveFlags(_RecipeRow row) {
    logger.i(
        'IVSMHandler: SAVE FLAGS: flags=0x${row.flags.toRadixString(16)} fval=0x${row.fval.toRadixString(16)}');
    // If this row carries clip metadata (by convention: SN_CLIP/OT_CLIP via EVENT_ARG and MTYPE), map into collection
    if (row.eventCode == 'G') {
      // Populate a slot for clip update; exact field mapping depends on CSV, reuse eventArg as epoch for logging
      final _ClipSlot slot = _ClipSlot(
        clipId:
            row.msgId & 0xFFFF, // Best-effort, CSV may carry explicit clip IDs
        recipeType: row.mtype,
        eventByte: 'G'.codeUnitAt(0),
        epoch: row.endDay,
      );
      _updateClipsCollection(slot);
    }
  }

  void _handleNullEvent(_RecipeRow row) {
    logger.t('IVSMHandler: NULL event (no-op) seq=${row.seq}');
  }

  void _handlePlayEvent(String groupName, _RecipeRow row) {
    logger.i(
        'IVSMHandler: PLAY [$groupName] msgId=${row.msgId} mtype=${row.mtype} stype=${row.subType}');
    _msgUidToRow[row.msgId] = row;
    // Update clips collection too (PLAY rows can include clip references)
    final _ClipSlot slot = _ClipSlot(
      clipId: row.msgId & 0xFFFF,
      recipeType: row.mtype,
      eventByte: 'P'.codeUnitAt(0),
      epoch: row.endDay,
    );
    _updateClipsCollection(slot);
  }

  void _handleSwitchMainRecipe(_RecipeRow row) {
    logger.i('IVSMHandler: SWITCH main recipe to id=${row.eventArg}');
  }

  Map<String, int> _parseCsvHeader(String headerLine) {
    final List<String> cols = _splitCsvLine(headerLine);
    final Map<String, int> map = <String, int>{};
    for (int i = 0; i < cols.length; i++) {
      map[cols[i].trim().toUpperCase()] = i;
    }
    return map;
  }

  List<String> _splitCsvLine(String line) {
    // Pipe-separated values with quoting
    final List<String> out = <String>[];
    final StringBuffer cur = StringBuffer();
    bool inQuotes = false;
    for (int i = 0; i < line.length; i++) {
      final String ch = line[i];
      if (ch == '"') {
        inQuotes = !inQuotes;
        continue;
      }
      if (ch == '|' && !inQuotes) {
        out.add(cur.toString());
        cur.clear();
        continue;
      }
      cur.write(ch);
    }
    out.add(cur.toString());
    return out;
  }

  _RecipeRow? _parseRecipeRow(List<String> cols, Map<String, int> hdr) {
    int parseInt(String name, {int def = 0}) {
      final int? idx = hdr[name];
      if (idx == null || idx < 0 || idx >= cols.length) return def;
      final String s = cols[idx].trim();
      if (s.isEmpty) return def;
      final bool hex = s.startsWith('0x') || s.startsWith('0X');
      final String s2 = hex ? s.substring(2) : s;
      return int.tryParse(s2, radix: hex ? 16 : 10) ?? def;
    }

    String parseString(String name) {
      final int? idx = hdr[name];
      if (idx == null || idx < 0 || idx >= cols.length) return '';
      return cols[idx].trim();
    }

    final int seq = parseInt('SEQ', def: 0);
    final int flags = parseInt('FLAGS', def: 0);
    final int fval = parseInt('FVAL', def: 0);
    final int stype = parseInt('STYPE', def: 2);
    final String trig = parseString('TRIG');
    final int start = parseInt('START', def: 0) + 0x4034;
    final int end = parseInt('END', def: 0) + 0x4034;
    final String event = parseString('EVENT');
    final int eventArg = parseInt('EVENT_ARG', def: 0);
    final int mtype = parseInt('MTYPE', def: 1);
    final int msgId = parseInt('MSG_ID', def: 0);

    final String ev = event.isEmpty ? '' : event[0].toUpperCase();
    final _RecipeRow row = _RecipeRow(
      seq: seq,
      flags: flags,
      fval: fval,
      subType: stype,
      trigger: trig.isEmpty ? 'A' : trig[0].toUpperCase(),
      startDay: start,
      endDay: end,
      eventCode: ev,
      eventArg: eventArg,
      mtype: mtype,
      msgId: msgId,
    );
    return row;
  }

  void _handleAudioClipCarousel(BitBuffer b) {
    // 16-bit signature, 8-bit clipId, skip 1 bit
    final int signature = b.readBits(16);
    final int clipId = b.readBits(8);
    b.skipBits(1);

    if (signature == 0) {
      logger
          .w('IVSMHandler: AUDIO CLIP SIGNATURE = 0 (AUDIO_CLIP_ID: $clipId)');
    }

    logger.t('IVSMHandler: Clip AU (Clip ID: $clipId, Signature: $signature)');

    // If clipId != 0, manage individual clip, otherwise treat as audio logo
    if (clipId != 0) {
      final _AudioClipEntry? existing = _clipEntries[clipId];
      if (existing != null &&
          existing.signature == signature &&
          existing.state == 2) {
        logger.t(
            'IVSMHandler: Clip $clipId is already saved (same signature: $signature)');
        return;
      }

      final _AudioClipFormatResult fmt = _readAudioClipFormat(b, 0x7d00);
      if (!fmt.ok) {
        if (fmt.errorCode == 5) {
          logger.t('IVSMHandler: Clip $clipId is not in the list');
        } else {
          logger
              .w('IVSMHandler: Clip processing failed: code=${fmt.errorCode}');
        }
        return;
      }

      _clipEntries[clipId] = _AudioClipEntry(
        signature: signature,
        state: 2,
        encoder: fmt.encoder,
        eventByte: fmt.eventByte,
        bytes: fmt.bytes,
      );
      logger.i(
          'IVSMHandler: SAVED CLIP (ID: $clipId, SIGNATURE: $signature, encoder: ${fmt.encoder}, event: ${fmt.eventByte}, bytes: ${fmt.bytes.length})');
      return;
    }

    // Audio logo path (clipId == 0)
    if (_audioLogo != null &&
        _audioLogo!.state == 2 &&
        _audioLogo!.signature == signature) {
      logger.t(
          'IVSMHandler: Audio Logo is already saved (same signature: $signature)');
      return;
    }

    final _AudioClipFormatResult fmt = _readAudioClipFormat(b, 0x2000);
    if (!fmt.ok) {
      logger.w(
          'IVSMHandler: Audio logo processing failed: code=${fmt.errorCode}');
      return;
    }
    _audioLogo = _AudioClipEntry(
      signature: signature,
      state: 2,
      encoder: fmt.encoder,
      eventByte: fmt.eventByte,
      bytes: fmt.bytes,
    );
    logger.i(
        'IVSMHandler: SAVED AUDIO LOGO (SIGNATURE: $signature, bytes: ${fmt.bytes.length})');
  }

  void _handleConfigurationCarousel(BitBuffer b) {
    // Signature (16), reserved(1), then zlib stream holding config text
    final int signature = b.readBits(16);
    b.skipBits(1);
    if (b.hasError) {
      logger.w('IVSMHandler: Failed to read CONFIG signature');
      return;
    }

    if (signature == 0) {
      logger.w('IVSMHandler: CONFIG SIGNATURE = 0');
    }

    logger.i('IVSMHandler: Config AU (Signature: $signature)');

    // If same as last processed, ignore
    if (_lastConfigSignature == signature) {
      logger.i('IVSMHandler: Ignored CONFIG AU (same signature: $signature)');
      return;
    }

    // Read uncompressed size from trailing 4 bytes before end of stream
    final List<int> zbytes = b.viewRemainingData;
    final int readUncompressedSize = _readZlibTrailerUncompressedSize(zbytes);
    if (readUncompressedSize <= 0 || readUncompressedSize > 0x2000) {
      logger.w(
          'IVSMHandler: Invalid Config uncompressed size: $readUncompressedSize (sig $signature)');
      return;
    }
    logger.t('IVSMHandler: Read uncompressed size: $readUncompressedSize');

    final int zres = _checkZlibFlagsBytes(zbytes);
    if (zres != 0) {
      // 0 OK, 2 read err, 0xb invalid header/flag
      return;
    }

    try {
      final List<int> raw = ZLibDecoder().convert(zbytes);
      if (raw.length != readUncompressedSize) {
        logger.w(
            'IVSMHandler: Config readUncompressedSize ($readUncompressedSize) != actual (${raw.length}) sig=$signature');
      }

      // Ensure null-terminated, then parse
      final String text = utf8.decode(raw, allowMalformed: true);
      logger.d('IVSMHandler: Uncompressed CONFIG:\n$text');

      final _ConfigAccumulator acc = _ConfigAccumulator();
      final int rc = _processConfigurationText(text, acc);
      if (rc != 0) {
        logger
            .w('IVSMHandler: FAILED TO PROCESS CONFIG (signature $signature)');
      } else {
        _lastConfigSignature = signature;
        logger.i(
            'IVSMHandler: PROCESSED CONFIG (signature: ${signature.toString().padLeft(5, '0')})');
        logger.i(
            'IVSMHandler: Config current: remindMeLaterDelay=${_cfgRemindMeLaterDelay?.toString() ?? 'n/a'} defaultTuneSid=${_cfgDefaultTuneSid?.toString() ?? 'n/a'} ipUrl=${_cfgIpUrl ?? 'n/a'} pagUrl=${_cfgPagUrl ?? 'n/a'}');
      }
    } catch (e) {
      logger.e('IVSMHandler: Config Deflate failed (signature $signature): $e');
    }
  }

  int _readZlibTrailerUncompressedSize(List<int> z) {
    if (z.length < 4) return 0;
    // Sum of last four bytes, each shifted by 8*n
    int size = 0;
    for (int i = 0; i < 4; i++) {
      final int b = z[z.length - 4 + i] & 0xFF;
      size |= (b << (i * 8));
    }
    return size;
  }

  // Consume to end-of-line or until length exhausted, returns 0 on EOL found else 5
  int _consumeLineAndZero(List<int> buf, _ConfigCursor cur) {
    while (cur.remaining > 0) {
      final int ch = buf[cur.offset];
      if (ch == 0x0A) {
        // Zero current, advance and break
        buf[cur.offset] = 0;
        cur.offset += 1;
        cur.remaining -= 1;
        break;
      }
      buf[cur.offset] = 0;
      cur.offset += 1;
      cur.remaining -= 1;
    }
    return cur.remaining > 0 ? 0 : 5;
  }

  // Skip spaces, zeroing them, returns 0 on success, 5 if len exhausted
  int _skipSpacesAndZero(List<int> buf, _ConfigCursor cur) {
    while (true) {
      int isSpace = 0;
      if (cur.remaining > 0) {
        if (buf[cur.offset] == 0x20) isSpace = 1;
      }
      if (isSpace == 0) break;
      buf[cur.offset] = 0;
      cur.offset += 1;
      cur.remaining -= 1;
    }
    return cur.remaining > 0 ? 0 : 5;
  }

  // Case-insensitive prefix compare, returns 1 if a equals b ignoring case
  int _compareStringCaseInsensitive(String a, String b) {
    int i = 0;
    while (true) {
      final int ca = i < a.length ? a.codeUnitAt(i) : 0;
      final int cb = i < b.length ? b.codeUnitAt(i) : 0;
      if (cb != _toLowerByte(ca)) return 0;
      if (ca == 0) break;
      i += 1;
      if (i > a.length && i > b.length) break;
      if (i > a.length) break;
      if (i > b.length) break;
    }
    return 1;
  }

  int _toLowerByte(int c) {
    final int a = 'A'.codeUnitAt(0);
    final int z = 'Z'.codeUnitAt(0);
    if (c >= a && c <= z) return c + 32;
    return c & 0xFF;
  }

  // Convert numeric string with range check, returns 0 on ok, else 0xb for format, 0xc for range
  int _strToIntMaybe(
      String s, int minVal, int maxVal, void Function(int) store) {
    final String trimmed = s.trimLeft();
    if (trimmed.isEmpty) return 0x0b;
    int? v;
    try {
      v = int.parse(trimmed);
    } catch (_) {
      return 0x0b;
    }
    if (v < minVal || v > maxVal) return 0x0c;
    store(v);
    return 0;
  }

  // Process and save single config param, returns 0 on ok, 0xc on unsupported/invalid
  int _saveConfigParam(String name, String value, _ConfigAccumulator acc) {
    logger.t('IVSMHandler: Saving parameter: $name = $value');

    // Recognized params
    if (_compareStringCaseInsensitive('remindmelaterdelay', name) == 1) {
      return _strToIntMaybe(value, 0, 9, (v) {
        acc.remindMeLaterDelay = v;
        acc.anySaved = true;
        _cfgRemindMeLaterDelay = v;
      });
    }
    if (_compareStringCaseInsensitive('defaulttunesid', name) == 1) {
      return _strToIntMaybe(value, 1, 0x1ff, (v) {
        acc.defaultTuneSid = v;
        acc.anySaved = true;
        _cfgDefaultTuneSid = v;
      });
    }
    if (_compareStringCaseInsensitive('ivsmipurl', name) == 1) {
      acc.ivsmIpUrl = value;
      acc.anySaved = true;
      _cfgIpUrl = value;
      return 0;
    }
    if (_compareStringCaseInsensitive('ivsmpagurl', name) == 1) {
      acc.ivsmPagUrl = value;
      acc.anySaved = true;
      _cfgPagUrl = value;
      return 0;
    }

    logger.w('IVSMHandler: Ignored unsupported parameter: $name = $value');
    return 0x0c;
  }

  // Stream-like processor for config text, comments starting with #, empty lines, newline as 0x0A
  int _processConfigurationText(String text, _ConfigAccumulator acc) {
    // Operate on mutable bytes to emulate zeroing during parse
    final List<int> buf = utf8.encode(text);
    final _ConfigCursor cur = _ConfigCursor(offset: 0, remaining: buf.length);
    // processedOk removed, rely on logging per-parameter
    while (true) {
      if (cur.remaining == 0) return 0; // Done
      final int c0 = buf[cur.offset];
      if (c0 == 0x0A || c0 == 0x23) {
        // Newline or '#'
        logger.t('IVSMHandler: Skipped commented or empty line');
        _consumeLineAndZero(buf, cur);
        continue;
      }

      // Mark start of name
      final int nameStart = cur.offset;
      int result;
      while (true) {
        if (cur.remaining == 0) {
          logger.w('IVSMHandler: No separator found while parsing name');
          return 0x0b;
        }
        final int ch = buf[cur.offset];
        if (ch == 0x3A) {
          buf[cur.offset] = 0;
          cur.offset += 1;
          cur.remaining -= 1;
          final String name = _decodeCString(buf, nameStart);
          if (name.isEmpty) {
            logger.w('IVSMHandler: Param name is empty');
            result = 0x0b;
            break;
          }
          if (_skipSpacesAndZero(buf, cur) != 0) {
            logger.w('IVSMHandler: No parameter value found');
            result = 0x0b;
            break;
          }
          final int valueStart = cur.offset;
          // Advance until EOL or len
          while (cur.remaining > 0 && buf[cur.offset] != 0x0A) {
            cur.offset += 1;
            cur.remaining -= 1;
          }
          _consumeLineAndZero(buf, cur);
          final String value = _decodeCString(buf, valueStart);
          result = _saveConfigParam(name, value, acc);
          break;
        }
        if ((ch <= 0x20 && ch != 0x09)) {
          // Whitespace in name is invalid (excluding tab?)
          logger.w('IVSMHandler: Invalid param name format');
          return 0x0b;
        }
        cur.offset += 1;
        cur.remaining -= 1;
      }

      if (result == 0x0c) {
        // Continue, 0x0c means unsupported or out-of-range, loop ends on EOF
      } else if (result == 0x0b) {
        // Format error, continue scanning next line
      }
    }
  }

  String _decodeCString(List<int> buf, int start) {
    int end = start;
    while (end < buf.length && buf[end] != 0) {
      end++;
    }
    if (end <= start) return '';
    return utf8.decode(buf.sublist(start, end), allowMalformed: true);
  }

  int _checkIvsmId(_IvsmIdIndex index, int targetPrefix20, int targetSuffix16) {
    final int normalizedPrefix = targetPrefix20 & 0xFFFFF;
    final int normalizedSuffix = targetSuffix16 & 0xFFFF;

    int? previousPrefix;
    for (final _IvsmPrefixEntry entry in index.entries) {
      if (previousPrefix != null && entry.prefix20 < previousPrefix) {
        previousPrefix = entry.prefix20;
        continue;
      }
      previousPrefix = entry.prefix20;

      if (entry.prefix20 > normalizedPrefix) {
        return 5;
      }
      if (entry.prefix20 < normalizedPrefix) {
        continue;
      }

      if (entry.isTree) {
        if (entry.upperList == null) return 2;
        return _checkListContents(entry.upperList!, normalizedSuffix);
      }

      if (entry.count == 1) {
        final int suffix = entry.singleSuffix ?? -1;
        return suffix == normalizedSuffix ? 0 : 5;
      }

      final List<int>? suffixes = entry.suffixList;
      if (suffixes == null) return 2;
      for (final int sfx in suffixes) {
        if (sfx == normalizedSuffix) return 0;
        if (sfx > normalizedSuffix) break;
      }
      return 5;
    }
    return 5;
  }

  int _checkListContents(List<_IvsmUpperEntry> uppers, int targetSuffix16) {
    final int targetUpper = (targetSuffix16 >> 12) & 0xF;
    final int targetLower12 = targetSuffix16 & 0xFFF;
    int? previousUpper;
    for (final _IvsmUpperEntry e in uppers) {
      if (previousUpper != null && e.upperNibble < previousUpper) {
        previousUpper = e.upperNibble;
        continue;
      }
      previousUpper = e.upperNibble;

      if (e.upperNibble > targetUpper) {
        return 5;
      }
      if (e.upperNibble < targetUpper) {
        continue;
      }
      return _checkLowerData(e.lowerData, targetLower12);
    }
    return 5;
  }

  int _checkLowerData(_IvsmLowerData lowerData, int targetLower12) {
    if (lowerData.lowers != null) {
      final List<int> lowers = lowerData.lowers!;
      for (final int val in lowers) {
        if (val == targetLower12) return 0;
        if (val > targetLower12) break;
      }
      return 5;
    }
    final List<_IvsmMidEntry>? mids = lowerData.mids;
    if (mids == null) return 2;
    final int targetMid8 = (targetLower12 >> 4) & 0xFF;
    final int targetLeaf4 = targetLower12 & 0xF;
    for (final _IvsmMidEntry mid in mids) {
      if (mid.mid8 == targetMid8) {
        return _checkLeafCondition(mid.leaf, targetLeaf4);
      }
    }
    return 5;
  }

  int _checkLeafCondition(_IvsmLeafCondition cond, int targetLeaf4) {
    if (cond.singleLeaf4 != null) {
      return cond.singleLeaf4 == targetLeaf4 ? 0 : 5;
    }
    if (cond.bitmask16 != null) {
      final int mask = cond.bitmask16! & 0xFFFF;
      final bool allowed = ((mask >> targetLeaf4) & 1) != 0;
      return allowed ? 0 : 5;
    }
    return 2;
  }

  // Attempts to derive IVSM prefix/suffix from AppState.radioId (ASCII digits)
  (_IvsmIdPair?, String) _getDeviceIvsmIdPairOrLog() {
    try {
      final List<int>? rid = sxiLayer.appState.radioId;
      if (rid == null || rid.isEmpty) {
        return (null, 'radioId unavailable');
      }
      final String ridStr = String.fromCharCodes(rid).trim();
      final String digits = ridStr.replaceAll(RegExp(r'[^0-9]'), '');
      if (digits.isEmpty) {
        return (null, 'radioId non-numeric');
      }
      // Parse as BigInt to be safe, derive prefix20/suffix16 from 36 LSBs
      final BigInt v = BigInt.parse(digits);
      final int suffix16 = (v & BigInt.from(0xFFFF)).toInt();
      final int prefix20 = ((v >> 16) & BigInt.from(0xFFFFF)).toInt();
      final _IvsmIdPair pair =
          _IvsmIdPair(prefix20: prefix20, suffix16: suffix16);
      logger.t(
          'IVSMHandler: Derived IVSM ID from radioId=$ridStr => prefix=0x${prefix20.toRadixString(16).padLeft(5, '0')} suffix=0x${suffix16.toRadixString(16).padLeft(4, '0')}');
      return (pair, 'radioId-derived');
    } catch (e) {
      logger.t('IVSMHandler: Unable to derive IVSM ID from radioId: $e');
      return (null, 'radioId parse error');
    }
  }
}

class _IvsmIdIndex {
  final List<_IvsmPrefixEntry> entries;
  const _IvsmIdIndex({required this.entries});
}

class _IvsmPrefixEntry {
  final int prefix20;
  final bool isTree;
  final int count;
  final int offsetOrSuffix;
  int? singleSuffix;
  List<int>? suffixList;
  List<_IvsmUpperEntry>? upperList;

  _IvsmPrefixEntry({
    required this.prefix20,
    required this.isTree,
    required this.count,
    required this.offsetOrSuffix,
  });
}

class _IvsmUpperEntry {
  final int upperNibble;
  final _IvsmLowerData lowerData;
  const _IvsmUpperEntry({required this.upperNibble, required this.lowerData});
}

class _IvsmLowerData {
  final List<_IvsmMidEntry>? mids;
  final List<int>? lowers;

  const _IvsmLowerData._({this.mids, this.lowers});
  factory _IvsmLowerData.midLeaf(List<_IvsmMidEntry> mids) =>
      _IvsmLowerData._(mids: mids);
  factory _IvsmLowerData.lowerList(List<int> lowers) =>
      _IvsmLowerData._(lowers: lowers);
}

class _IvsmMidEntry {
  final int mid8;
  final _IvsmLeafCondition leaf;
  const _IvsmMidEntry({required this.mid8, required this.leaf});
}

class _IvsmLeafCondition {
  final int? singleLeaf4;
  final int? bitmask16;
  const _IvsmLeafCondition._({this.singleLeaf4, this.bitmask16});
  factory _IvsmLeafCondition.single(int leaf4) =>
      _IvsmLeafCondition._(singleLeaf4: leaf4);
  factory _IvsmLeafCondition.bitmask(int mask16) =>
      _IvsmLeafCondition._(bitmask16: mask16);
}

class _IvsmIdPair {
  final int prefix20;
  final int suffix16;
  const _IvsmIdPair({required this.prefix20, required this.suffix16});
}

class _AudioClipEntry {
  final int signature;
  final int state;
  final int encoder;
  final int eventByte;
  final List<int> bytes;
  const _AudioClipEntry({
    required this.signature,
    required this.state,
    required this.encoder,
    required this.eventByte,
    required this.bytes,
  });
}

class _ClipSlot {
  final int clipId;
  final int recipeType;
  final int eventByte;
  final int epoch;
  const _ClipSlot({
    required this.clipId,
    required this.recipeType,
    required this.eventByte,
    required this.epoch,
  });
}

class _AudioClipFormatResult {
  final bool ok;
  final int errorCode;
  final int encoder;
  final int eventByte;
  final List<int> bytes;
  const _AudioClipFormatResult(
      {required this.ok,
      required this.errorCode,
      required this.encoder,
      required this.eventByte,
      required this.bytes});
}

class _IvsmAssignmentInfo {
  final int? mainRecipeId;
  final int? ftaRecipeId;
  final int? dataRecipeId;
  final int? dayA;
  final int? dayB;
  final bool resetHideFlags;

  const _IvsmAssignmentInfo({
    required this.mainRecipeId,
    required this.ftaRecipeId,
    required this.dataRecipeId,
    required this.dayA,
    required this.dayB,
    required this.resetHideFlags,
  });
}

class _RecipeRow {
  final int seq;
  final int flags;
  final int fval;
  final int subType;
  final String trigger;
  final int startDay;
  final int endDay;
  final String eventCode;
  final int eventArg;
  final int mtype;
  final int msgId;

  const _RecipeRow({
    required this.seq,
    required this.flags,
    required this.fval,
    required this.subType,
    required this.trigger,
    required this.startDay,
    required this.endDay,
    required this.eventCode,
    required this.eventArg,
    required this.mtype,
    required this.msgId,
  });
}

class _ConfigCursor {
  int offset;
  int remaining;
  _ConfigCursor({required this.offset, required this.remaining});
}

class _ConfigAccumulator {
  int? remindMeLaterDelay;
  int? defaultTuneSid;
  String? ivsmIpUrl;
  String? ivsmPagUrl;
  bool anySaved = false;
}
