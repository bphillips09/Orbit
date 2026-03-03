// Weather Dialog UI
import 'package:flutter/material.dart';
import 'package:orbit/data/weather/tabular_weather_state.dart';
import 'package:orbit/ui/radar_map_dialog.dart';
import 'package:orbit/ui/tabular_weather_dialog.dart';
import 'package:orbit/ui/weather_alerts_dialog.dart';

class WeatherDialog extends StatelessWidget {
  final TabularWeatherState tabularWeatherState;

  const WeatherDialog({super.key, required this.tabularWeatherState});

  static Future<void> show(
    BuildContext context, {
    required TabularWeatherState tabularWeatherState,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (_) => WeatherDialog(tabularWeatherState: tabularWeatherState),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: SizedBox(
          width: 1120,
          height: 760,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Weather',
                        style: TextStyle(fontSize: 18),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(text: 'Forecast', icon: Icon(Icons.cloud_outlined)),
                  Tab(text: 'Radar', icon: Icon(Icons.radar)),
                  Tab(text: 'Alerts', icon: Icon(Icons.notification_important)),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    TabularWeatherDialog(
                      tabularWeatherState: tabularWeatherState,
                      embedded: true,
                    ),
                    const RadarMapDialog(embedded: true),
                    WeatherAlertsDialog(
                      tabularWeatherState: tabularWeatherState,
                      embedded: true,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
