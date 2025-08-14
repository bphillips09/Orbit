import 'package:orbit/helpers.dart';
import 'package:orbit/sxi_indication_types.dart';
import 'package:orbit/data/access_unit.dart';
import 'package:orbit/data/bit_buffer.dart';
import 'package:orbit/sxi_layer.dart';
import 'package:orbit/logging.dart';

// Data Stream Identifier (DSI) Handler
abstract class DSIHandler {
  final DataServiceIdentifier dsi;
  final SXiLayer sxiLayer;

  DSIHandler(this.dsi, this.sxiLayer);

  void onAccessUnitComplete(AccessUnit unit);
}

// Album Art Handler
class AlbumArtHandler extends DSIHandler {
  final Map<int, Map<int, AccessUnitGroup>> auGroups = {};

  AlbumArtHandler(SXiLayer sxiLayer)
      : super(DataServiceIdentifier.albumArt, sxiLayer);

  @override
  void onAccessUnitComplete(AccessUnit unit) {
    BitBuffer bitBuffer = BitBuffer(unit.getHeaderAndData());
    int pvn = bitBuffer.readBits(4);
    int carid = bitBuffer.readBits(3);

    if (pvn == 1) {
      if (carid == 0 || carid == 1) {
        try {
          handleImageData(bitBuffer);
        } catch (e) {
          logger.w("AlbumArtHandler: Error processing image data - $e");
        }
      } else if (carid == 2) {
        logger.d('AlbumArtHandler: Default assignment data received.');
      } else {
        logger.w("AlbumArtHandler: Unhandled Carousel ID: $carid");
      }
    } else {
      logger.w("AlbumArtHandler: Unhandled PVN: $pvn");
    }
  }

  void handleImageData(BitBuffer buffer) {
    int accessUnitTotal = 0;
    int accessUnitCount = 0;

    int programType = buffer.readBits(4);
    int imageType = buffer.readBits(3);

    if (imageType == 0) {
      int sid;
      int programId;

      if (programType == 0) {
        sid = buffer.readBits(10); // SID
        imageType = buffer.readBits(32); // ARG
        programId = imageType & 0x7FFFFFFF; // Mask out sign bit
      } else {
        if (programType != 4) {
          logger.w('AlbumArtHandler: Unsupported Program Type: $programType');
          return;
        }
        sid = buffer.readBits(10); // SID
        programId = buffer.readBits(8); // ARG
      }

      if (programType == 4) {
        programId |= sid << 16; // Combine SID and ARG
      }

      bool hasCaption = buffer.readBits(1) != 0;
      if (hasCaption) {
        int captionCharCount = 0;
        while (captionCharCount < 5) {
          int captionChar = buffer.readBits(5);
          if (captionChar == 0) break;
          captionCharCount++;
        }
      }

      bool hasExtendedData = buffer.readBits(1) != 0;
      if (hasExtendedData) {
        int extCnt = buffer.readBits(8);
        for (int i = 0; i < extCnt + 1; i++) {
          buffer.readBits(8);
        }
      }

      bool isAuGroup = buffer.readBits(1) != 0;
      if (isAuGroup) {
        int fieldSize = buffer.readBits(4);
        accessUnitTotal = buffer.readBits(fieldSize + 1);
        accessUnitCount = buffer.readBits(fieldSize + 1);
      }

      List<int> auData = buffer.remainingData;
      buffer.align(); // We probably need to always align to the byte boundary

      auGroups[sid] ??= {};
      var sidGroups = auGroups[sid]!;
      var auGroup = sidGroups[programId] ??= AccessUnitGroup(
          sid: sid, pid: programId, totalAUs: accessUnitTotal + 1);

      bool complete = auGroup.addUnit(accessUnitCount, auData);

      if (complete) {
        List<int> assembledImage = auGroup.assemble();
        handleCompleteImage(sid, programId, assembledImage);

        sidGroups.remove(programId);
        if (sidGroups.isEmpty) {
          auGroups.remove(sid);
        }
      }
    } else {
      logger.w('AlbumArtHandler: Unsupported Image Type: $imageType');
    }
  }

  void handleCompleteImage(int sid, int programId, List<int> image) {
    logger.t('AlbumArtHandler: Complete Image: $sid - $programId');
    sxiLayer.setProgramImage(sid, programId, image);
  }
}

// Channel Graphics Handler
class ChannelGraphicsHandler extends DSIHandler {
  ChannelGraphicsHandler(SXiLayer sxiLayer)
      : super(DataServiceIdentifier.albumArt, sxiLayer);

  @override
  void onAccessUnitComplete(AccessUnit unit) {
    BitBuffer bitBuffer = BitBuffer(unit.getHeaderAndData());
    int pvn = bitBuffer.readBits(4);
    int carid = bitBuffer.readBits(3);
    int _ = bitBuffer.readBits(1);

    if (pvn != 1 || carid != 0) {
      logger.w(
          "ChannelGraphicsHandler: Invalid PVN or Carousel ID: $pvn - $carid");
    }

    int mti = bitBuffer.readBits(8);
    switch (mti) {
      case 0x1:
      case 0x65:
        logger.t('ChannelGraphicsHandler: Category Reference Data');
        // Category Reference data
        // For linking background images and categories together
        // We don't need this for our implementation
        break;
      case 0x2:
      case 0x66:
      case 0x70:
        // Service Reference data
        // Links a SID to an image data reference
        logger.t('ChannelGraphicsHandler: Service Reference Data');

        var serviceReferenceData = parseServiceReferenceData(bitBuffer, mti);
        sxiLayer.appState
            .updateServiceGraphicsReferenceData(serviceReferenceData);
        break;
      case 0x8:
      case 0x76:
      case 0x6c:
        // Dynamic Service Reference data
        // Links a SID to a temporary image data reference
        logger.t('ChannelGraphicsHandler: Dynamic Service Reference Data');

        var serviceReferenceData = parseServiceReferenceData(bitBuffer, mti);
        sxiLayer.appState
            .updateServiceGraphicsReferenceData(serviceReferenceData);
        break;
      case 0x9:
      case 0x77:
        // Channel Graphics data
        logger.t('ChannelGraphicsHandler: Channel Graphics Data');

        var logoData = parseLargeLogoData(bitBuffer, mti);
        if (logoData != null) {
          sxiLayer.appState.updateChannelGraphicsImage(logoData);
        }
        break;
      case 0xA:
      case 0x6E:
        logger.t('ChannelGraphicsHandler: Background Image Data');
        // Channel Category Background Image Data
        // We don't need this currently
        break;
      default:
        logger.w('ChannelGraphicsHandler: Unhandled Graphic Type: $mti');
    }
  }

  List<ServiceGraphicsReference> parseServiceReferenceData(
      BitBuffer bitBuffer, int mti) {
    // Base Layer Sequence?
    bitBuffer.skipBits(8);
    int overlayLayerSequence = bitBuffer.readBits(8);
    int baseLayerPowerUpIndication = bitBuffer.readBits(8);
    // Overlay Power Up Indication?
    bitBuffer.skipBits(8);

    List<ServiceGraphicsReference> table = [];

    // Process each entry
    for (int entryIndex = 0;
        entryIndex < overlayLayerSequence && entryIndex < 0xff;
        entryIndex++) {
      // Read the Service ID (SID) and adjust for certain MTI types
      int sid = bitBuffer.readBits(8);
      if (mti == 0x70 || mti == 0x76) {
        sid += 0x100;
      }

      // Only process valid SIDs
      if (sid < 0x180) {
        // Read and possibly adjust the channel logo ID
        int chanLogoId = bitBuffer.readBits(8);
        if ((mti == 0x70 || mti == 0x76) && chanLogoId < 0x80) {
          chanLogoId += 0x100;
        }

        // Read first bit-group: 1 bit then 7 bits (chanLogoSeqLow)
        // DB search order low, don't need it
        bitBuffer.skipBits(1);
        int chanLogoSeqLow = bitBuffer.readBits(7);

        // Read the 8-bit background image ID
        int backgroundImageIdRaw = bitBuffer.readBits(8);

        // Read next bit-group: 1 bit then 7 bits (bgSeqHigh)
        // DB search order high, don't need it
        bitBuffer.skipBits(1);
        int bgSeqHigh = bitBuffer.readBits(7);

        // Skip extra bits as indicated by the base layer power-up indication
        bitBuffer.skipBits(baseLayerPowerUpIndication * 8);

        // Build word1 using bitCombine(backgroundImageIdRaw, 0x1)
        // Its low byte becomes the Valid flag (always 0x1) and the high byte is the background image ID
        int word1 = bitCombine(backgroundImageIdRaw, 0x1);

        // Extract fields from the combined words
        int valid = word1 & 0xff; // Should be 0x1 if valid

        if (valid != 1) continue;

        int chanLogoSeqNum = bitCombine(bgSeqHigh, chanLogoSeqLow) & 0xff;

        // Create the entry
        ServiceGraphicsReference entry = ServiceGraphicsReference(
          sid: sid,
          referenceId: chanLogoId,
          sequence: chanLogoSeqNum,
        );

        // Store the entry at index 'sid' in the table
        table.add(entry);
      } else {
        // For SIDs that exceed the maximum, skip the appropriate bits
        bitBuffer.skipBits(0x20);
        bitBuffer.skipBits(baseLayerPowerUpIndication * 8);
      }
    }
    return table;
  }

  ChannelLogoInfo? parseLargeLogoData(BitBuffer bitBuffer, int mti) {
    int chanLogoId = bitBuffer.readBits(8);
    if (mti == 0x77) {
      chanLogoId += 0x100;
    }
    if (chanLogoId >= 0x180) {
      // Logo ID out-of-range; skip or ignore this message.
      return null;
    }

    // Parse the logo header fields
    // First, clear and read word0:
    // Skip 1 bit then read 7 bits. (the 7-bit value becomes the high byte)
    bitBuffer.skipBits(1);
    int seqPart = bitBuffer.readBits(7);
    // We reserve the low byte of word0 for the Status (which will later be forced to 1).
    int headerWord0 = (seqPart << 8);

    // Next, read 8 bits to form headerWord1.
    int headerWord1 = bitBuffer.readBits(8);

    // Skip the next 4 bytes (32 bits) and then 1 + 1 + 6 bits (8 bits total).
    bitBuffer.skipBits(32);
    bitBuffer.skipBits(1);
    bitBuffer.skipBits(1);
    bitBuffer.skipBits(6);

    // Process the data that determines image validity
    int extraLengthIndication = bitBuffer.readBits(8);
    int logoValidityField = 0;
    if (extraLengthIndication < 5) {
      // Not enough bytes, skip the indicated number and mark image invalid
      bitBuffer.skipBits(extraLengthIndication * 8);
      logoValidityField = 0xffffffff;
    } else {
      // Read an extra byte; it should equal 0x43 for a valid image
      int checkChar = bitBuffer.readBits(8);
      if (checkChar != 0x43) {
        // If not, skip the remaining extra bytes
        bitBuffer.skipBits((extraLengthIndication - 1) * 8);
        logoValidityField = 0xffffffff;
      } else {
        // Valid extra indication: read a 32-bit validity field
        logoValidityField = bitBuffer.readBits(32);
        // Skip any remaining extra bytes
        bitBuffer.skipBits((extraLengthIndication - 5) * 8);
      }
    }
    // Check the validity flag: if bit 6 is not set, the image is not valid
    if (((logoValidityField >> 6) & 1) == 0) {
      return null;
    }

    // Read a 16-bit primary image length
    int imageDataLen = bitBuffer.readBits(16);

    // Read the image data bytes
    List<int> imageData = bitBuffer.readBytes(imageDataLen);

    // Read two additional 16-bit words for the remaining header info
    int headerWord2 = bitBuffer.readBits(16);
    int headerWord3 = bitBuffer.readBits(16);

    // Map header words to the struct fields
    // Word0: high byte is SeqNum
    int seqNum = (headerWord0 >> 8) & 0xFF;
    // We force status to 1 (indicating successful processing)
    int status = 1;
    // Word1: low byte is RevNum, high byte is BkgrndBitmapIndex
    int revNum = headerWord1 & 0xFF;
    int bkgrndBitmapIndex = (headerWord1 >> 8) & 0xFF;
    // Word2 and Word3: extract background color and the secondary image flag
    int bkgrndColorRed = (headerWord2 >> 8) & 0xFF;
    int bkgrndColorGreen = headerWord2 & 0xFF;
    int bkgrndColorBlue = (headerWord3 >> 8) & 0xFF;
    int containsSecondaryImage = headerWord3 & 0xFF;
    int secondaryImageDataLen = 0;

    GraphicsColor bkgrndColor = GraphicsColor(
      red: bkgrndColorRed,
      green: bkgrndColorGreen,
      blue: bkgrndColorBlue,
    );

    return ChannelLogoInfo(
      chanLogoId: chanLogoId,
      status: status,
      seqNum: seqNum,
      revNum: revNum,
      bkgrndBmpIndex: bkgrndBitmapIndex,
      bkgrndColor: bkgrndColor,
      hasSecondaryImage: containsSecondaryImage,
      imageDataLen: imageDataLen,
      secondaryImageDataLen: secondaryImageDataLen,
      imageData: imageData,
    );
  }
}

// Program Guide Handler
class ProgramGuideHandler extends DSIHandler {
  ProgramGuideHandler(SXiLayer sxiLayer)
      : super(DataServiceIdentifier.electronicProgramGuide, sxiLayer);

  @override
  void onAccessUnitComplete(AccessUnit unit) {
    BitBuffer bitBuffer = BitBuffer(unit.getHeaderAndData());
    int version = bitBuffer.readBits(4);
    int messageType = bitBuffer.readBits(3);

    if (version == 1) {
      switch (messageType) {
        case 0x0:
        case 0x1:
          logger.d('ProgramGuideHandler: Schedule Message');
          break;
        case 0x2:
          logger.d('ProgramGuideHandler: Program Announcement Message');
          break;
        case 0x3:
          logger.d('ProgramGuideHandler: Table Affinity Message');
          break;
        case 0x4:
          logger.d('ProgramGuideHandler: Profile Configuration Message');
          break;
        case 0x5:
          logger.d('ProgramGuideHandler: Segment Versioning Message');
          break;
      }

      logger.t(
          'ProgramGuideHandler remaining data len: ${bitBuffer.viewRemainingData.length}');
    } else {
      logger.w("ProgramGuideHandler Invalid EPG Version: $version");
    }
  }
}

// Tabular Weather Handler
class TabularWeatherHandler extends DSIHandler {
  TabularWeatherHandler(SXiLayer sxiLayer)
      : super(DataServiceIdentifier.sxmWeatherTabular, sxiLayer);

  @override
  void onAccessUnitComplete(AccessUnit unit) {
    BitBuffer bitBuffer = BitBuffer(unit.getHeaderAndData());
    int pvn = bitBuffer.readBits(4);
    int carid = bitBuffer.readBits(3);

    if (pvn == 1) {
      logger.t('TabularWeatherHandler: messageType: $carid');
      logger.t(
          'TabularWeatherHandler: remaining data len: ${bitBuffer.viewRemainingData.length}');

      // Map remaining data to hex
      String remainingDataHex = bitBuffer.viewRemainingData
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      logger.t('TabularWeatherHandler: Remaining data: $remainingDataHex');

      // Add detailed debugging for each message type
      switch (carid) {
        case 0:
          // Forecast Weather Report
          logger.d(
              'TabularWeatherHandler: Processing message type 0 (Forecast Weather Report)');
          break;
        case 1:
          // Ski Condition Report
          logger.d(
              'TabularWeatherHandler: Processing message type 1 (Ski Condition Report)');
          break;
        case 2:
          // Reliable File Delivery (Weather Data)
          logger.d(
              'TabularWeatherHandler: Processing message type 2 (Reliable File Delivery (Weather Data))');
          break;
        case 3:
          // Metadata update for RFD
          logger.d(
              'TabularWeatherHandler: Processing message type 3 (Metadata update for RFD)');
          break;
        default:
          logger.w('TabularWeatherHandler: Unknown message type: $carid');
      }
    } else {
      logger.w("TabularWeatherHandler: Invalid Version: $pvn");
    }
  }
}

// IVSM Handler
class IVSMHandler extends DSIHandler {
  IVSMHandler(SXiLayer sxiLayer) : super(DataServiceIdentifier.ivsm, sxiLayer);

  @override
  void onAccessUnitComplete(AccessUnit unit) {
    BitBuffer bitBuffer = BitBuffer(unit.getHeaderAndData());
    int pvn = bitBuffer.readBits(4);
    int carid = bitBuffer.readBits(3);

    if (pvn == 1) {
      switch (carid) {
        case 0:
          logger.d('IVSMHandler: Radio Assignment Carousel');
          break;
        case 1:
          logger.d('IVSMHandler: Recipe Carousel');
          break;
        case 2:
          logger.d('IVSMHandler: Audio Clip Carousel');
          break;
        case 3:
          logger.d('IVSMHandler: Configuration Carousel');
          break;
      }
    } else {
      logger.w("IVSMHandler: Invalid Version: $pvn");
    }
  }
}

// Service Graphics Reference (maps sid to a reference id and sequence number)
class ServiceGraphicsReference {
  final int sid;
  final int referenceId;
  final int sequence;

  ServiceGraphicsReference({
    required this.sid,
    required this.referenceId,
    required this.sequence,
  });

  @override
  String toString() {
    return 'ServiceGraphicsReference(sid: $sid, referenceId: $referenceId, sequence: $sequence)\n';
  }
}

// Channel Logo Info (maps a logo to a reference id and sequence number)
class ChannelLogoInfo {
  final int chanLogoId;
  final int status;
  final int seqNum;
  final int revNum;
  final int bkgrndBmpIndex;
  final GraphicsColor? bkgrndColor;
  final int hasSecondaryImage;
  final int imageDataLen;
  final int secondaryImageDataLen;
  final List<int> imageData;

  ChannelLogoInfo({
    required this.chanLogoId,
    this.status = 0,
    required this.seqNum,
    this.revNum = 0,
    this.bkgrndBmpIndex = 0,
    this.bkgrndColor,
    this.hasSecondaryImage = 0,
    this.imageDataLen = 0,
    this.secondaryImageDataLen = 0,
    required this.imageData,
  });

  @override
  String toString() {
    return 'ChannelLogoInfo(chanLogoId: $chanLogoId, seqNum: $seqNum, imageDataLen: ${imageData.length})\n';
  }
}

// Graphics Color (RGB values of the image)
class GraphicsColor {
  final int red;
  final int green;
  final int blue;

  GraphicsColor({required this.red, required this.green, required this.blue});

  @override
  String toString() => 'GraphicsColor(red: $red, green: $green, blue: $blue)';
}
