import 'package:orbit/crc.dart';
import 'package:orbit/data/access_unit.dart';
import 'package:orbit/data/bit_buffer.dart';
import 'package:orbit/data/data_handler.dart';
import 'package:orbit/logging.dart';
import 'package:orbit/sxi_indication_types.dart';
import 'package:orbit/sxi_layer.dart';

class MovieTimesHandler extends DSIHandler {
  MovieTimesHandler(SXiLayer sxiLayer)
      : super(DataServiceIdentifier.movieTimes, sxiLayer);

  @override
  void onAccessUnitComplete(AccessUnit unit) {
    final BitBuffer bitBuffer = BitBuffer(unit.getHeaderAndData());
    final int pvn = bitBuffer.readBits(4);
    final int carid = bitBuffer.readBits(3);

    logger.t('MovieTimesHandler: PVN: $pvn CARID: $carid');

    if (pvn != 1) {
      logger.w('MovieTimesHandler: Invalid Version: $pvn');
      return;
    }

    // Validate AU CRC against header+payload
    try {
      if (!CRC32.check(unit.getHeaderAndData(), unit.crc)) {
        logger.e('MovieTimesHandler: CRC check failed for AU (CARID $carid)');
        return;
      }
    } catch (_) {
      logger.e('MovieTimesHandler: CRC check failed (exception)');
      return;
    }

    switch (carid) {
      case 0:
        logger.d('MovieTimesHandler: Descriptions AU received');
        break;
      case 1:
        logger.d('MovieTimesHandler: Times AU received');
        break;
      case 2:
        logger.d('MovieTimesHandler: RFD AU received');
        break;
      case 3:
        logger.d('MovieTimesHandler: Metadata AU received');
        break;
      default:
        logger.w('MovieTimesHandler: Unknown CARID $carid');
        break;
    }

    logger.t(
        'MovieTimesHandler: Incoming AU (CARID: $carid, Size: ${unit.data.length})');
  }
}
