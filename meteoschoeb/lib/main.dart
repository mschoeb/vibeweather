import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'models/weather_models.dart';
import 'services/weather_service.dart';
import 'widgets/forecast_chart.dart';

void main() {
  runApp(const MeteoSchoebApp());
}

class MeteoSchoebApp extends StatelessWidget {
  const MeteoSchoebApp({super.key, this.service});

  final WeatherService? service;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MeteoSchoeb',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B1120),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2DD4BF),
          brightness: Brightness.dark,
          surface: const Color(0xFF131C31),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF131C31),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
        ),
      ),
      home: WeatherHomePage(service: service ?? WeatherService()),
    );
  }
}

class WeatherHomePage extends StatefulWidget {
  const WeatherHomePage({super.key, required this.service});

  final WeatherService service;

  @override
  State<WeatherHomePage> createState() => _WeatherHomePageState();
}

class _WeatherHomePageState extends State<WeatherHomePage> {
  late Future<WeatherBundle> _weatherFuture;
  bool _showRawIcon = true;
  bool _showSpread = true;

  @override
  void initState() {
    super.initState();
    _weatherFuture = widget.service.fetchWeather();
  }

  Future<void> _refresh() async {
    final next = widget.service.fetchWeather();
    setState(() {
      _weatherFuture = next;
    });
    await next;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: FutureBuilder<WeatherBundle>(
          future: _weatherFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting &&
                !snapshot.hasData) {
              return const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Color(0xFF2DD4BF)),
                    SizedBox(height: 16),
                    Text(
                      'Loading Schoebcast & live KLO data…',
                      style: TextStyle(color: Color(0xFF94A3B8)),
                    ),
                  ],
                ),
              );
            }

            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.cloud_off_rounded,
                        size: 48,
                        color: Color(0xFF94A3B8),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Could not load weather forecast',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${snapshot.error}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: _refresh,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              );
            }

            final bundle = snapshot.data!;
            return RefreshIndicator(
              color: const Color(0xFF2DD4BF),
              onRefresh: _refresh,
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                    children: [
                      _buildTopBar(bundle.forecast),
                      const SizedBox(height: 12),
                      _buildHeroCard(bundle),
                      const SizedBox(height: 16),
                      _buildTemperatureCard(bundle),
                      const SizedBox(height: 20),
                      _buildFooter(bundle.forecast),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildTopBar(KloForecast forecast) {
    final runLabel = DateFormat('HH:mm').format(forecast.reftime);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.location_on_rounded,
                    size: 18,
                    color: Color(0xFF2DD4BF),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    forecast.station.name,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '${forecast.station.code} • ${forecast.station.elevationM.round()} m • ICON-CH1 $runLabel UTC',
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: _refresh,
          tooltip: 'Refresh forecast',
          icon: const Icon(Icons.refresh_rounded, color: Color(0xFFCBD5E1)),
        ),
      ],
    );
  }

  Widget _buildHeroCard(WeatherBundle bundle) {
    final klo = bundle.forecast;
    final fh = klo.forecast;
    final live = bundle.latestObservation;

    // Next 24h upcoming Schoebcast min / max
    final nowUtc = DateTime.now().toUtc();
    final upcomingTemps = <double>[];
    for (int i = 0; i < fh.length; i++) {
      final diffH = fh.timestamps[i].difference(nowUtc).inMinutes / 60.0;
      if (diffH >= -0.5 && diffH <= 24.5) {
        upcomingTemps.add(fh.schoebcastTempC[i]);
      }
    }
    final rangeTemps = upcomingTemps.isNotEmpty ? upcomingTemps : fh.schoebcastTempC;
    final low24 = rangeTemps.reduce(math.min);
    final high24 = rangeTemps.reduce(math.max);

    final currentTemp = live?.temperatureC ?? klo.lookback.temperatureC.last;
    final currentTimeLocal =
        (live?.timestampUtc ?? klo.lookback.timestamps.last).toLocal();
    final windKmh =
        ((live?.windSpeedMs ?? klo.lookback.windSpeedMs.last) * 3.6).round();
    final windDir =
        compassDirection(live?.windDirDeg ?? klo.lookback.windDirDeg.last);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF162440), Color(0xFF0F1B33)],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: live != null
                                ? const Color(0xFF2DD4BF)
                                : const Color(0xFF94A3B8),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          live != null
                              ? 'Live KLO • ${DateFormat('HH:mm').format(currentTimeLocal)}'
                              : 'Latest obs • ${DateFormat('HH:mm').format(currentTimeLocal)}',
                          style: const TextStyle(
                            color: Color(0xFF94A3B8),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${currentTemp.toStringAsFixed(1)}°',
                      style: const TextStyle(
                        fontSize: 56,
                        fontWeight: FontWeight.w300,
                        height: 1.0,
                        letterSpacing: -2,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2DD4BF).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFF2DD4BF).withValues(alpha: 0.35),
                      ),
                    ),
                    child: const Text(
                      'Schoebcast v1',
                      style: TextStyle(
                        color: Color(0xFF2DD4BF),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'H ${high24.toStringAsFixed(1)}°  L ${low24.toStringAsFixed(1)}°',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFE2E8F0),
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Next 24h range',
                    style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Divider(color: Colors.white.withValues(alpha: 0.08), height: 1),
          const SizedBox(height: 12),
          Wrap(
            spacing: 20,
            runSpacing: 8,
            children: [
              _statPill(Icons.air_rounded, 'Wind', '$windKmh km/h $windDir'),
              if (live?.humidityPct != null)
                _statPill(
                  Icons.water_drop_outlined,
                  'Humidity',
                  '${live!.humidityPct!.round()}%',
                ),
              if (live?.precipMm != null)
                _statPill(
                  Icons.umbrella_outlined,
                  'Precip (10m)',
                  '${live!.precipMm!.toStringAsFixed(1)} mm',
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statPill(IconData icon, String label, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: const Color(0xFF94A3B8)),
        const SizedBox(width: 6),
        Text(
          '$label ',
          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
        ),
        Text(
          value,
          style: const TextStyle(
            color: Color(0xFFE2E8F0),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildTemperatureCard(WeatherBundle bundle) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 18, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Temperature Forecast (33h)',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                _toggleChip(
                  label: 'Raw ICON',
                  active: _showRawIcon,
                  color: const Color(0xFF60A5FA),
                  onTap: () => setState(() => _showRawIcon = !_showRawIcon),
                ),
                const SizedBox(width: 6),
                _toggleChip(
                  label: 'Spread',
                  active: _showSpread,
                  color: const Color(0xFF60A5FA),
                  onTap: () => setState(() => _showSpread = !_showSpread),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [
                _legendItem(const Color(0xFF2DD4BF), 'Schoebcast'),
                if (_showRawIcon)
                  _legendItem(const Color(0xFF60A5FA), 'ICON mean', dashed: true),
                if (_showSpread)
                  _legendItem(
                    const Color(0xFF60A5FA).withValues(alpha: 0.35),
                    'ICON p10–p90',
                    isBox: true,
                  ),
                _legendItem(const Color(0xFFF8FAFC), 'Observed KLO'),
              ],
            ),
            const SizedBox(height: 16),
            ForecastChart(
              bundle: bundle,
              showRawIcon: _showRawIcon,
              showSpread: _showSpread,
            ),
          ],
        ),
      ),
    );
  }

  Widget _toggleChip({
    required String label,
    required bool active,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active
              ? color.withValues(alpha: 0.16)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active
                ? color.withValues(alpha: 0.5)
                : Colors.white.withValues(alpha: 0.1),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? color : const Color(0xFF94A3B8),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _legendItem(
    Color color,
    String label, {
    bool dashed = false,
    bool isBox = false,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: isBox ? 10 : 3,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
            border: dashed ? Border.all(color: color, width: 1) : null,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
        ),
      ],
    );
  }

  Widget _buildFooter(KloForecast forecast) {
    final genLocal = DateFormat('dd.MM.yyyy HH:mm').format(forecast.generatedAt.toLocal());
    return Column(
      children: [
        Text(
          '${forecast.attribution} • ICON-CH1-EPS & SwissMetNet',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
        ),
        const SizedBox(height: 2),
        Text(
          'Model ${forecast.model} • Updated $genLocal',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFF475569), fontSize: 11),
        ),
      ],
    );
  }
}
