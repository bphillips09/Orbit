// Album Art Handler
import 'package:orbit/data/access_unit.dart';
import 'package:orbit/data/data_handler.dart';
import 'package:orbit/data/bit_buffer.dart';
import 'package:orbit/sxi_indication_types.dart';
import 'package:orbit/sxi_layer.dart';
import 'package:orbit/logging.dart';

class AlbumArtHandler extends DSIHandler {
  final Map<int, Map<int, AccessUnitGroup>> auGroups = {};

  AlbumArtHandler(SXiLayer sxiLayer)
      : super(DataServiceIdentifier.albumArt, sxiLayer);

  @override
  void onAccessUnitComplete(AccessUnit unit) {
    final List<int> auBytes = unit.getHeaderAndData();
    BitBuffer bitBuffer = BitBuffer(auBytes);
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
