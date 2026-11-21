import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/weather_models.dart';

class WeatherService {
  WeatherService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const String _hostedBaseUrl = 'https://mschoeb.github.io/vibeweather/';
  static const String _smnNowUrl =
      'https://data.geo.admin.ch/ch.meteoschweiz.ogd-smn/klo/ogd-smn_klo_t_now.csv';

  Uri _resolveDataUri(String relativePath) {
    final cacheBust = DateTime.now().millisecondsSinceEpoch.toString();
    if (kIsWeb) {
      final host = Uri.base.host;
      final isLocal = host == 'localhost' || host == '127.0.0.1' || host.isEmpty;
      if (!isLocal) {
        return Uri.base.resolve('$relativePath?t=$cacheBust');
      }
    }
    return Uri.parse('$_hostedBaseUrl$relativePath?t=$cacheBust');
  }

  Future<WeatherBundle> fetchWeather() async {
    final forecastFuture = _fetchForecast('data/klo.json');
    final liveObsFuture = _fetchLiveObservations().catchError((_) => <LiveObservation>[]);
    final historyFuture = fetchHistoryIndex().catchError((_) => <HistoryRunEntry>[]);

    final results = await Future.wait<dynamic>([
      forecastFuture,
      liveObsFuture,
      historyFuture,
    ]);
    return WeatherBundle(
      forecast: results[0] as KloForecast,
      liveObservations: results[1] as List<LiveObservation>,
      historyRuns: results[2] as List<HistoryRunEntry>,
    );
  }

  Future<KloForecast> fetchRunForecast(HistoryRunEntry entry) {
    return _fetchForecast('data/${entry.file}');
  }

  Future<List<HistoryRunEntry>> fetchHistoryIndex() async {
    final uri = _resolveDataUri('data/history.json');
    final response = await _client.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      return const [];
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final runs = decoded['runs'] as List<dynamic>? ?? const [];
    return runs
        .map((e) => HistoryRunEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<KloForecast> _fetchForecast(String relativePath) async {
    final uri = _resolveDataUri(relativePath);
    final response = await _client.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('Failed to load $relativePath (${response.statusCode})');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return KloForecast.fromJson(decoded);
  }

  Future<List<LiveObservation>> _fetchLiveObservations() async {
    final cacheBust = DateTime.now().millisecondsSinceEpoch ~/ 60000;
    final uri = Uri.parse('$_smnNowUrl?t=$cacheBust');
    final response = await _client.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      return const [];
    }

    final text = utf8.decode(response.bodyBytes);
    final lines = const LineSplitter().convert(text);
    if (lines.length < 2) return const [];

    final header = lines.first.split(';');
    final tsIdx = header.indexOf('reference_timestamp');
    final tempIdx = header.indexOf('tre200s0');
    final wspdIdx = header.indexOf('fkl010z0');
    final wdirIdx = header.indexOf('dkl010z0');
    final humIdx = header.indexOf('ure200s0');
    final precipIdx = header.indexOf('rre150z0');

    if (tsIdx < 0 || tempIdx < 0) return const [];

    final obs = <LiveObservation>[];
    for (int i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final cols = line.split(';');
      if (cols.length <= tsIdx) continue;

      final ts = _parseSwissTimestampUtc(cols[tsIdx]);
      if (ts == null) continue;

      obs.add(
        LiveObservation(
          timestampUtc: ts,
          temperatureC: _parseDouble(cols, tempIdx),
          windSpeedMs: _parseDouble(cols, wspdIdx),
          windDirDeg: _parseDouble(cols, wdirIdx),
          humidityPct: _parseDouble(cols, humIdx),
          precipMm: _parseDouble(cols, precipIdx),
        ),
      );
    }
    return obs;
  }

  static DateTime? _parseSwissTimestampUtc(String raw) {
    // Format: dd.MM.yyyy HH:mm (UTC)
    final parts = raw.trim().split(' ');
    if (parts.length != 2) return null;
    final dateParts = parts[0].split('.');
    final timeParts = parts[1].split(':');
    if (dateParts.length != 3 || timeParts.length != 2) return null;
    final day = int.tryParse(dateParts[0]);
    final month = int.tryParse(dateParts[1]);
    final year = int.tryParse(dateParts[2]);
    final hour = int.tryParse(timeParts[0]);
    final minute = int.tryParse(timeParts[1]);
    if (day == null || month == null || year == null || hour == null || minute == null) {
      return null;
    }
    return DateTime.utc(year, month, day, hour, minute);
  }

  static double? _parseDouble(List<String> cols, int idx) {
    if (idx < 0 || idx >= cols.length) return null;
    final s = cols[idx].trim();
    if (s.isEmpty || s == '-') return null;
    return double.tryParse(s);
  }
}
