import 'package:orbit/data/access_unit.dart';
import 'package:orbit/data/bit_buffer.dart';
import 'package:orbit/data/data_handler.dart';
import 'package:orbit/logging.dart';
import 'package:orbit/sxi_indication_types.dart';
import 'package:orbit/sxi_layer.dart';

class UnhandledHandler extends DSIHandler {
  final Map<int, Map<int, AccessUnitGroup>> auGroups = {};

  UnhandledHandler(SXiLayer sxiLayer)
      : super(DataServiceIdentifier.none, sxiLayer);

  @override
  void onAccessUnitComplete(AccessUnit unit) {
    final List<int> auBytes = unit.getHeaderAndData();
    BitBuffer bitBuffer = BitBuffer(auBytes);
    int pvn = bitBuffer.readBits(4);
    int carid = bitBuffer.readBits(3);

    logger.d(
        'UnhandledHandler: ASCII in bytes: ${String.fromCharCodes(auBytes)}');

    logger.d('UnhandledHandler: PVN: $pvn CARID: $carid');

    if (pvn == 1) {
      if (carid == 0 || carid == 1) {
        logger.d('UnhandledHandler: AU received, bytes: ${auBytes.length}');
      } else if (carid == 2) {
        logger.d('UnhandledHandler: Default assignment data received.');
      } else {
        logger.w("UnhandledHandler: Unhandled Carousel ID: $carid");
      }
    } else {
      logger.w("UnhandledHandler: Unhandled PVN: $pvn");
    }
  }
}
