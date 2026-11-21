import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meteoschoeb/main.dart';
import 'package:meteoschoeb/models/weather_models.dart';
import 'package:meteoschoeb/services/weather_service.dart';

class _FakeWeatherService extends WeatherService {
  @override
  Future<WeatherBundle> fetchWeather() async {
    final ref = DateTime.utc(2026, 11, 21, 12);
    return WeatherBundle(
      forecast: KloForecast(
        station: const StationInfo(
          code: 'KLO',
          name: 'Zürich / Kloten',
          latitude: 47.4796,
          longitude: 8.5360,
          elevationM: 426.3,
        ),
        model: 'schoebcast_klo_gru_v1',
        reftime: ref,
        generatedAt: ref.add(const Duration(hours: 2)),
        attribution: 'Source: MeteoSwiss',
        lookback: LookbackHourly(
          timestamps: List.generate(6, (i) => ref.subtract(Duration(hours: 5 - i))),
          temperatureC: [4.0, 4.5, 5.0, 6.0, 7.0, 8.0],
          windSpeedMs: [2.0, 2.1, 2.2, 2.5, 2.8, 3.0],
          windDirDeg: [220, 225, 230, 235, 240, 245],
        ),
        forecast: ForecastHourly(
          timestamps: List.generate(6, (i) => ref.add(Duration(hours: i + 1))),
          schoebcastTempC: [8.8, 9.2, 8.5, 7.4, 6.5, 5.9],
          iconTempMeanC: [8.0, 8.4, 7.8, 6.9, 6.0, 5.5],
          iconTempStdC: [0.4, 0.5, 0.5, 0.6, 0.6, 0.7],
          iconTempMinC: [7.2, 7.5, 7.0, 6.0, 5.1, 4.5],
          iconTempMaxC: [8.8, 9.2, 8.7, 7.9, 7.0, 6.6],
          iconTempP10C: [7.5, 7.8, 7.2, 6.3, 5.4, 4.8],
          iconTempP90C: [8.5, 8.9, 8.4, 7.5, 6.7, 6.2],
          iconWindSpeedMeanMs: [3.2, 3.5, 3.0, 2.8, 2.4, 2.1],
          iconWindSpeedMinMs: [2.0, 2.2, 1.8, 1.5, 1.3, 1.0],
          iconWindSpeedMaxMs: [4.5, 4.9, 4.2, 4.0, 3.6, 3.2],
          iconWindDirDeg: [240, 245, 250, 255, 260, 265],
        ),
      ),
      liveObservations: [
        LiveObservation(
          timestampUtc: ref.add(const Duration(hours: 1)),
          temperatureC: 9.1,
          windSpeedMs: 3.1,
          windDirDeg: 240,
          humidityPct: 72,
          precipMm: 0.0,
        ),
      ],
    );
  }
}

void main() {
  testWidgets('MeteoSchoeb renders KLO forecast and attribution', (tester) async {
    await tester.pumpWidget(MeteoSchoebApp(service: _FakeWeatherService()));
    await tester.pumpAndSettle();

    expect(find.text('Zürich / Kloten'), findsOneWidget);
    expect(find.text('9.1°'), findsOneWidget);
    expect(find.text('Temperature Forecast (33h)'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.textContaining('Source: MeteoSwiss'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Source: MeteoSwiss'), findsOneWidget);
  });
}
