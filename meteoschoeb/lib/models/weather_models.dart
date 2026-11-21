class StationInfo {
  const StationInfo({
    required this.code,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.elevationM,
  });

  final String code;
  final String name;
  final double latitude;
  final double longitude;
  final double elevationM;

  factory StationInfo.fromJson(Map<String, dynamic> json) {
    return StationInfo(
      code: json['code'] as String,
      name: json['name'] as String,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      elevationM: (json['elevation_m'] as num).toDouble(),
    );
  }
}

class LookbackHourly {
  const LookbackHourly({
    required this.timestamps,
    required this.temperatureC,
    required this.windSpeedMs,
    required this.windDirDeg,
  });

  final List<DateTime> timestamps;
  final List<double> temperatureC;
  final List<double> windSpeedMs;
  final List<double> windDirDeg;

  factory LookbackHourly.fromJson(Map<String, dynamic> json) {
    return LookbackHourly(
      timestamps: (json['timestamps'] as List<dynamic>)
          .map((e) => DateTime.parse(e as String).toUtc())
          .toList(),
      temperatureC: _toDoubleList(json['temperature_c']),
      windSpeedMs: _toDoubleList(json['wind_speed_ms']),
      windDirDeg: _toDoubleList(json['wind_dir_deg']),
    );
  }
}

class ForecastHourly {
  const ForecastHourly({
    required this.timestamps,
    required this.schoebcastTempC,
    required this.iconTempMeanC,
    required this.iconTempStdC,
    required this.iconTempMinC,
    required this.iconTempMaxC,
    required this.iconTempP10C,
    required this.iconTempP90C,
    required this.iconWindSpeedMeanMs,
    required this.iconWindSpeedMinMs,
    required this.iconWindSpeedMaxMs,
    required this.iconWindDirDeg,
    this.actualTempC = const [],
  });

  final List<DateTime> timestamps;
  final List<double> schoebcastTempC;
  final List<double> iconTempMeanC;
  final List<double> iconTempStdC;
  final List<double> iconTempMinC;
  final List<double> iconTempMaxC;
  final List<double> iconTempP10C;
  final List<double> iconTempP90C;
  final List<double> iconWindSpeedMeanMs;
  final List<double> iconWindSpeedMinMs;
  final List<double> iconWindSpeedMaxMs;
  final List<double> iconWindDirDeg;
  final List<double?> actualTempC;

  int get length => timestamps.length;

  factory ForecastHourly.fromJson(Map<String, dynamic> json) {
    final rawActual = json['actual_temp_c'] as List<dynamic>?;
    return ForecastHourly(
      timestamps: (json['timestamps'] as List<dynamic>)
          .map((e) => DateTime.parse(e as String).toUtc())
          .toList(),
      schoebcastTempC: _toDoubleList(json['schoebcast_temp_c']),
      iconTempMeanC: _toDoubleList(json['icon_temp_mean_c']),
      iconTempStdC: _toDoubleList(json['icon_temp_std_c']),
      iconTempMinC: _toDoubleList(json['icon_temp_min_c']),
      iconTempMaxC: _toDoubleList(json['icon_temp_max_c']),
      iconTempP10C: _toDoubleList(json['icon_temp_p10_c']),
      iconTempP90C: _toDoubleList(json['icon_temp_p90_c']),
      iconWindSpeedMeanMs: _toDoubleList(json['icon_wind_speed_mean_ms']),
      iconWindSpeedMinMs: _toDoubleList(json['icon_wind_speed_min_ms']),
      iconWindSpeedMaxMs: _toDoubleList(json['icon_wind_speed_max_ms']),
      iconWindDirDeg: _toDoubleList(json['icon_wind_dir_deg']),
      actualTempC: rawActual == null
          ? const []
          : rawActual.map((e) => e == null ? null : (e as num).toDouble()).toList(),
    );
  }
}

class KloForecast {
  const KloForecast({
    required this.station,
    required this.model,
    required this.reftime,
    required this.generatedAt,
    required this.attribution,
    required this.lookback,
    required this.forecast,
  });

  final StationInfo station;
  final String model;
  final DateTime reftime;
  final DateTime generatedAt;
  final String attribution;
  final LookbackHourly lookback;
  final ForecastHourly forecast;

  factory KloForecast.fromJson(Map<String, dynamic> json) {
    return KloForecast(
      station: StationInfo.fromJson(json['station'] as Map<String, dynamic>),
      model: json['model'] as String,
      reftime: DateTime.parse(json['reftime'] as String).toUtc(),
      generatedAt: DateTime.parse(json['generated_at'] as String).toUtc(),
      attribution: json['attribution'] as String? ?? 'Source: MeteoSwiss',
      lookback: LookbackHourly.fromJson(
        json['lookback_hourly'] as Map<String, dynamic>,
      ),
      forecast: ForecastHourly.fromJson(
        json['forecast_hourly'] as Map<String, dynamic>,
      ),
    );
  }
}

class LiveObservation {
  const LiveObservation({
    required this.timestampUtc,
    this.temperatureC,
    this.windSpeedMs,
    this.windDirDeg,
    this.humidityPct,
    this.precipMm,
  });

  final DateTime timestampUtc;
  final double? temperatureC;
  final double? windSpeedMs;
  final double? windDirDeg;
  final double? humidityPct;
  final double? precipMm;
}

class HistoryRunEntry {
  const HistoryRunEntry({
    required this.reftime,
    required this.file,
    required this.model,
    required this.verifiedHours,
    this.maeSchoebcast,
    this.maeIcon,
  });

  final DateTime reftime;
  final String file;
  final String model;
  final int verifiedHours;
  final double? maeSchoebcast;
  final double? maeIcon;

  factory HistoryRunEntry.fromJson(Map<String, dynamic> json) {
    return HistoryRunEntry(
      reftime: DateTime.parse(json['reftime'] as String).toUtc(),
      file: json['file'] as String,
      model: json['model'] as String? ?? 'schoebcast_klo_gru_v1',
      verifiedHours: (json['verified_hours'] as num?)?.toInt() ?? 0,
      maeSchoebcast: (json['mae_schoebcast'] as num?)?.toDouble(),
      maeIcon: (json['mae_icon'] as num?)?.toDouble(),
    );
  }
}

class WeatherBundle {
  const WeatherBundle({
    required this.forecast,
    required this.liveObservations,
    this.historyRuns = const [],
  });

  final KloForecast forecast;
  final List<LiveObservation> liveObservations;
  final List<HistoryRunEntry> historyRuns;

  LiveObservation? get latestObservation {
    for (int i = liveObservations.length - 1; i >= 0; i--) {
      if (liveObservations[i].temperatureC != null) {
        return liveObservations[i];
      }
    }
    return null;
  }
}

List<double> _toDoubleList(dynamic list) {
  return (list as List<dynamic>).map((e) => (e as num).toDouble()).toList();
}

String compassDirection(double deg) {
  const dirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  final idx = (((deg % 360) + 360) % 360 / 45.0).round() % 8;
  return dirs[idx];
}
