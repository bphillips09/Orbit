// Weather Alerts UI
import 'package:flutter/material.dart';
import 'package:orbit/data/handlers/weather_alerts_handler.dart';
import 'package:orbit/data/weather/tabular_weather_state.dart';
import 'package:orbit/logging.dart' show logger;

class WeatherAlertsDialog extends StatelessWidget {
  final TabularWeatherState tabularWeatherState;
  final bool embedded;

  const WeatherAlertsDialog({
    super.key,
    required this.tabularWeatherState,
    this.embedded = false,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: tabularWeatherState,
      builder: (context, _) {
        final List<WeatherAlertMessage> history =
            tabularWeatherState.weatherAlerts;
        final List<WeatherAlertMessage> active =
            tabularWeatherState.activeWeatherAlerts;
        if (history.isEmpty) {
          return const Center(
            child: Text('No weather alerts received yet'),
          );
        }
        if (active.isEmpty) {
          return Center(
            child: Text(
              'No active weather alerts\n(${history.length} received in session)',
              textAlign: TextAlign.center,
            ),
          );
        }
        return ListView.separated(
          padding: EdgeInsets.all(embedded ? 12 : 16),
          itemCount: active.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final WeatherAlertMessage a = active[index];
            // When clicked, log the payload
            return ElevatedButton(
              onPressed: () {
                logger.i('Alert payload: ${a.rawAu}');
                final WeatherAlertsHandler? h =
                    WeatherAlertsHandler.activeInstance;
                if (h != null) {
                  logger.i(h.decodeRawAlertPayloadWithContext(a.rawAu));
                } else {
                  logger.i(WeatherAlertsHandler.decodeRawAlertPayloadForDebug(
                      a.rawAu));
                }
              },
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Active alerts: ${active.length}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Alert Type ${a.alertTypeId}  •  Message ${a.messageId}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Section ${a.sectionIndex}/${a.sectionCount}'
                      '${a.assembledFromSections ? ' (assembled)' : ''}',
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'StateBit ${a.stateBit}  CARID ${a.carid}  '
                      'Language ${weatherAlertLanguageLabel(a.languageId)}  '
                      'Priority ${a.priority}  Scope ${weatherAlertLocationScopeLabel(a.locationScopeId)}  '
                      'Locations ${a.locationIds.length}',
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Received ${a.receivedAt.toLocal()}  •  AU ${a.payloadLengthBytes} bytes',
                    ),
                    if (a.locationIds.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Location IDs: ${a.locationIds.take(20).join(', ')}'
                        '${a.locationIds.length > 20 ? ' …' : ''}',
                      ),
                    ],
                    if (a.alertText != null && a.alertText!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text('Alert text: ${a.alertText}'),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
