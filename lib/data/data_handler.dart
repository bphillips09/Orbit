import 'package:orbit/sxi_indication_types.dart';
import 'package:orbit/data/access_unit.dart';
import 'package:orbit/sxi_layer.dart';

// Data Stream Identifier (DSI) Handler
abstract class DSIHandler {
  final DataServiceIdentifier dsi;
  final SXiLayer sxiLayer;

  DSIHandler(this.dsi, this.sxiLayer);

  void onAccessUnitComplete(AccessUnit unit);
}
