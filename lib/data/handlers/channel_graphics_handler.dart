// Channel Graphics Handler
import 'package:orbit/data/access_unit.dart';
import 'package:orbit/data/bit_buffer.dart';
import 'package:orbit/data/data_handler.dart';
import 'package:orbit/helpers.dart';
import 'package:orbit/logging.dart';
import 'package:orbit/sxi_indication_types.dart';
import 'package:orbit/sxi_layer.dart';

class ChannelGraphicsHandler extends DSIHandler {
  ChannelGraphicsHandler(SXiLayer sxiLayer)
      : super(DataServiceIdentifier.channelGraphicsUpdates, sxiLayer);

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
    // Base Layer Sequence
    bitBuffer.skipBits(8);
    int overlayLayerSequence = bitBuffer.readBits(8);
    int baseLayerPowerUpIndication = bitBuffer.readBits(8);
    // Overlay Power Up Indication
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
