import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meteoschoeb/main.dart';
import 'package:meteoschoeb/models/weather_models.dart';
import 'package:meteoschoeb/services/weather_service.dart';

class _FakeWeatherService extends WeatherService {
  KloForecast _makeRun(DateTime ref, {List<double?> actuals = const []}) {
    return KloForecast(
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
        actualTempC: actuals,
      ),
    );
  }

  @override
  Future<WeatherBundle> fetchWeather() async {
    final refLatest = DateTime.utc(2026, 11, 21, 15);
    final refPrev = DateTime.utc(2026, 11, 21, 12);
    return WeatherBundle(
      forecast: _makeRun(refLatest, actuals: [9.0, 9.1, null, null, null, null]),
      liveObservations: [
        LiveObservation(
          timestampUtc: refLatest.add(const Duration(hours: 1)),
          temperatureC: 9.1,
          windSpeedMs: 3.1,
          windDirDeg: 240,
          humidityPct: 72,
          precipMm: 0.0,
        ),
      ],
      historyRuns: [
        HistoryRunEntry(
          reftime: refLatest,
          file: 'runs/2026-11-21T1500Z.json',
          model: 'schoebcast_klo_gru_v1',
          verifiedHours: 2,
          maeSchoebcast: 0.25,
          maeIcon: 0.55,
        ),
        HistoryRunEntry(
          reftime: refPrev,
          file: 'runs/2026-11-21T1200Z.json',
          model: 'schoebcast_klo_gru_v1',
          verifiedHours: 5,
          maeSchoebcast: 0.31,
          maeIcon: 0.84,
        ),
      ],
    );
  }

  @override
  Future<KloForecast> fetchRunForecast(HistoryRunEntry entry) async {
    return _makeRun(entry.reftime, actuals: [8.6, 9.0, 8.4, 7.6, 6.7, null]);
  }
}

void main() {
  testWidgets('MeteoSchoeb renders live forecast and historic runs panel', (tester) async {
    await tester.pumpWidget(MeteoSchoebApp(service: _FakeWeatherService()));
    await tester.pumpAndSettle();

    expect(find.text('Zürich / Kloten'), findsOneWidget);
    expect(find.text('9.1°'), findsOneWidget);
    expect(find.text('Temperature Forecast (33h)'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Historic Runs'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Historic Runs'), findsOneWidget);
    expect(find.textContaining('Schoebcast 0.31° vs ICON 0.84°'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.textContaining('Source: MeteoSwiss'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Source: MeteoSwiss'), findsOneWidget);
  });
}
