import 'package:orbit/data/data_handler.dart';
import 'package:orbit/crc.dart';
import 'package:orbit/data/handlers/album_art_handler.dart';
import 'package:orbit/data/handlers/channel_graphics_handler.dart';
import 'package:orbit/data/handlers/ivsm_handler.dart';
import 'package:orbit/data/handlers/movie_times_handler.dart';
import 'package:orbit/data/handlers/program_guide_handler.dart';
import 'package:orbit/data/handlers/tabular_weather_handler.dart';
import 'package:orbit/sxi_indication_types.dart';
import 'package:orbit/data/sdtp.dart';
import 'package:orbit/data/access_unit.dart';
import 'package:orbit/sxi_layer.dart';
import 'package:orbit/logging.dart';

// SDTP Processor, processes SDTP packets and dispatches them to the appropriate DSI handler
// SDTP = SXM Dynamic Transport Protocol
// DMI = Data Multiplex Identifier
// DSI = Data Service Identifier
class SDTPProcessor {
  // Maps DMI to a list of SDTP packets currently being accumulated
  final Map<int, List<SDTPPacket>> activeDMIPackets = {};
  // Maps DMI to the expected number of packets (set from the SOA packet’s PLPC field)
  final Map<int, int> expectedPacketCount = {};
  // Track when the first packet for a DMI was seen, to cleanup stale collections
  final Map<int, DateTime> dmiFirstSeen = {};
  final Map<int, DSIHandler> dsiHandlers;

  // Constructor for handlers we've implemented so far
  SDTPProcessor(SXiLayer sxiLayer)
      : dsiHandlers = {
          DataServiceIdentifier.albumArt.value: AlbumArtHandler(sxiLayer),
          DataServiceIdentifier.channelGraphicsUpdates.value:
              ChannelGraphicsHandler(sxiLayer),
          DataServiceIdentifier.ivsm.value: IVSMHandler(sxiLayer),
          DataServiceIdentifier.movieTimes.value: MovieTimesHandler(sxiLayer),
          DataServiceIdentifier.electronicProgramGuide.value:
              ProgramGuideHandler(sxiLayer),
          DataServiceIdentifier.sxmWeatherTabular.value:
              TabularWeatherHandler(sxiLayer),
        };

  void processSDTPPacket(
      int dmi, DataServiceIdentifier dsi, SDTPPacket packet) {
    // If this packet marks the start of an AU, initialize its list and record the expected count
    if (packet.header.soa == 1) {
      activeDMIPackets[dmi] = [];
      // For non-final packets the PLPC is a countdown (4 means expect 5 packets)
      expectedPacketCount[dmi] = packet.header.plpc + 1;
      dmiFirstSeen[dmi] = DateTime.now();
    }

    // If we are accumulating packets for this DMI, add this one
    if (activeDMIPackets.containsKey(dmi)) {
      activeDMIPackets[dmi]!.add(packet);

      // When an End-Of-AU packet arrives, complete the AU
      if (packet.header.eoa == 1) {
        int received = activeDMIPackets[dmi]!.length;
        int expected = expectedPacketCount[dmi] ?? received;

        // If we don't have the expected number, try to reorder (using PSI) if possible
        // This literally has never worked once, I think it's always in order
        if (received != expected && packet.header.soa != 1) {
          logger.d('DMI $dmi: Expected $expected packets, received $received.');
          logger.d(
              'Warning: Packet count mismatch for DMI $dmi. Attempting reordering...');
          activeDMIPackets[dmi]!
              .sort((a, b) => a.header.psi.compareTo(b.header.psi));
        }

        // Create an AU from the ordered packets
        var accessUnit = AccessUnit.fromSDTPPackets(activeDMIPackets[dmi]!);
        activeDMIPackets.remove(dmi);
        expectedPacketCount.remove(dmi);
        dmiFirstSeen.remove(dmi);

        // Validate the assembled AU CRC
        if (!CRC32.check(accessUnit.getHeaderAndData(), accessUnit.crc)) {
          logger.d(
              'AU has invalid CRC32 for DMI: $dmi with handler: ${dsiHandlers[dsi.value]}');
          return;
        }

        // Hand off the complete AU to the DSI handler
        var handler = dsiHandlers[dsi.value];
        if (handler != null) {
          handler.onAccessUnitComplete(accessUnit);
        } else {
          logger.w('No handler for DSI: $dsi at time ${DateTime.now()}');
        }
      }
    }

    // Drop stale DMIs older than 300 seconds to avoid growth
    final cutoff = DateTime.now().subtract(const Duration(seconds: 300));
    final stale = dmiFirstSeen.entries
        .where((e) => e.value.isBefore(cutoff))
        .map((e) => e.key)
        .toList(growable: false);
    for (final key in stale) {
      logger.t('Dropping stale SDTP collection for DMI $key');
      activeDMIPackets.remove(key);
      expectedPacketCount.remove(key);
      dmiFirstSeen.remove(key);
    }
  }
}
