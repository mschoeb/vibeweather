import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/weather_models.dart';

class ForecastChart extends StatelessWidget {
  const ForecastChart({
    super.key,
    required this.bundle,
    required this.showRawIcon,
    required this.showSpread,
  });

  final WeatherBundle bundle;
  final bool showRawIcon;
  final bool showSpread;

  static const int _lookbackHoursToShow = 6;

  @override
  Widget build(BuildContext context) {
    final klo = bundle.forecast;
    final reftime = klo.reftime;
    final fh = klo.forecast;
    final lb = klo.lookback;

    // X coordinate is hours relative to reftime (e.g. -5 .. 0 for lookback, 1 .. 33 for forecast)
    double hoursFromRef(DateTime utc) =>
        utc.difference(reftime).inMinutes / 60.0;

    final lookbackSpots = <FlSpot>[];
    final startLb = math.max(0, lb.timestamps.length - _lookbackHoursToShow);
    for (int i = startLb; i < lb.timestamps.length; i++) {
      lookbackSpots.add(FlSpot(hoursFromRef(lb.timestamps[i]), lb.temperatureC[i]));
    }

    // Live 10-min observations after reftime (overlay onto active forecast!)
    final liveSpots = <FlSpot>[];
    if (lookbackSpots.isNotEmpty) {
      liveSpots.add(lookbackSpots.last);
    }
    for (final obs in bundle.liveObservations) {
      if (obs.temperatureC == null) continue;
      final x = hoursFromRef(obs.timestampUtc);
      if (x > 0 && x <= fh.length.toDouble()) {
        liveSpots.add(FlSpot(x, obs.temperatureC!));
      }
    }

    final schoebSpots = <FlSpot>[];
    final iconMeanSpots = <FlSpot>[];
    final iconP10Spots = <FlSpot>[];
    final iconP90Spots = <FlSpot>[];

    // Anchor forecast curves cleanly to t=0 lookback temperature visually? Keep forecast strictly +1..+33h
    for (int i = 0; i < fh.length; i++) {
      final x = hoursFromRef(fh.timestamps[i]);
      schoebSpots.add(FlSpot(x, fh.schoebcastTempC[i]));
      iconMeanSpots.add(FlSpot(x, fh.iconTempMeanC[i]));
      iconP10Spots.add(FlSpot(x, fh.iconTempP10C[i]));
      iconP90Spots.add(FlSpot(x, fh.iconTempP90C[i]));
    }

    final allY = <double>[
      ...lookbackSpots.map((s) => s.y),
      ...liveSpots.map((s) => s.y),
      ...schoebSpots.map((s) => s.y),
      if (showRawIcon) ...iconMeanSpots.map((s) => s.y),
      if (showSpread) ...iconP10Spots.map((s) => s.y),
      if (showSpread) ...iconP90Spots.map((s) => s.y),
    ];

    final minY = (allY.reduce(math.min) - 1.5).floorToDouble();
    final maxY = (allY.reduce(math.max) + 1.5).ceilToDouble();
    final minX = lookbackSpots.isNotEmpty ? lookbackSpots.first.x : 0.0;
    final maxX = fh.length.toDouble();

    final nowX = hoursFromRef(DateTime.now().toUtc());

    // Build bar list and track indices for BetweenBarsData and tooltips
    final bars = <LineChartBarData>[];
    int? p10Idx;
    int? p90Idx;

    if (showSpread) {
      p10Idx = bars.length;
      bars.add(
        LineChartBarData(
          spots: iconP10Spots,
          isCurved: true,
          curveSmoothness: 0.25,
          color: Colors.transparent,
          barWidth: 0,
          dotData: const FlDotData(show: false),
        ),
      );
      p90Idx = bars.length;
      bars.add(
        LineChartBarData(
          spots: iconP90Spots,
          isCurved: true,
          curveSmoothness: 0.25,
          color: Colors.transparent,
          barWidth: 0,
          dotData: const FlDotData(show: false),
        ),
      );
    }

    final lookbackBarIdx = bars.length;
    bars.add(
      LineChartBarData(
        spots: lookbackSpots,
        isCurved: true,
        curveSmoothness: 0.2,
        color: const Color(0xFF94A3B8),
        barWidth: 2,
        dotData: const FlDotData(show: false),
      ),
    );

    int? iconMeanBarIdx;
    if (showRawIcon) {
      iconMeanBarIdx = bars.length;
      bars.add(
        LineChartBarData(
          spots: iconMeanSpots,
          isCurved: true,
          curveSmoothness: 0.25,
          color: const Color(0xFF60A5FA),
          barWidth: 2,
          dashArray: const [6, 4],
          dotData: const FlDotData(show: false),
        ),
      );
    }

    final schoebBarIdx = bars.length;
    bars.add(
      LineChartBarData(
        spots: schoebSpots,
        isCurved: true,
        curveSmoothness: 0.25,
        color: const Color(0xFF2DD4BF),
        barWidth: 3,
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(
          show: true,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0xFF2DD4BF).withValues(alpha: 0.16),
              const Color(0xFF2DD4BF).withValues(alpha: 0.0),
            ],
          ),
        ),
      ),
    );

    int? liveBarIdx;
    if (liveSpots.length > 1) {
      liveBarIdx = bars.length;
      bars.add(
        LineChartBarData(
          spots: liveSpots,
          isCurved: false,
          color: const Color(0xFFF8FAFC),
          barWidth: 2.2,
          dotData: FlDotData(
            show: true,
            checkToShowDot: (spot, barData) => spot == liveSpots.last,
            getDotPainter: (spot, percent, bar, index) => FlDotCirclePainter(
              radius: 4.5,
              color: const Color(0xFFF8FAFC),
              strokeWidth: 2,
              strokeColor: const Color(0xFF0F172A),
            ),
          ),
        ),
      );
    }

    final betweenBars = <BetweenBarsData>[
      if (p10Idx != null && p90Idx != null)
        BetweenBarsData(
          fromIndex: p10Idx,
          toIndex: p90Idx,
          color: const Color(0xFF60A5FA).withValues(alpha: 0.18),
        ),
    ];

    final yInterval = ((maxY - minY) / 5).clamp(1.0, 5.0).ceilToDouble();

    return SizedBox(
      height: 250,
      child: LineChart(
        LineChartData(
          minX: minX,
          maxX: maxX,
          minY: minY,
          maxY: maxY,
          clipData: const FlClipData.all(),
          betweenBarsData: betweenBars,
          lineBarsData: bars,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: true,
            horizontalInterval: yInterval,
            verticalInterval: 6,
            getDrawingHorizontalLine: (value) => FlLine(
              color: Colors.white.withValues(alpha: value == 0 ? 0.22 : 0.07),
              strokeWidth: value == 0 ? 1.2 : 1,
            ),
            getDrawingVerticalLine: (_) => FlLine(
              color: Colors.white.withValues(alpha: 0.05),
              strokeWidth: 1,
            ),
          ),
          borderData: FlBorderData(show: false),
          extraLinesData: ExtraLinesData(
            verticalLines: [
              VerticalLine(
                x: 0,
                color: Colors.white.withValues(alpha: 0.2),
                strokeWidth: 1,
                dashArray: const [4, 4],
                label: VerticalLineLabel(
                  show: true,
                  alignment: Alignment.topRight,
                  padding: const EdgeInsets.only(left: 4, top: 2),
                  style: const TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                  labelResolver: (_) => 'Run',
                ),
              ),
              if (nowX >= minX && nowX <= maxX)
                VerticalLine(
                  x: nowX,
                  color: const Color(0xFFFBBF24).withValues(alpha: 0.65),
                  strokeWidth: 1.4,
                  dashArray: const [3, 3],
                  label: VerticalLineLabel(
                    show: true,
                    alignment: Alignment.topRight,
                    padding: const EdgeInsets.only(left: 4, top: 14),
                    style: const TextStyle(
                      color: Color(0xFFFBBF24),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                    labelResolver: (_) => 'Now',
                  ),
                ),
            ],
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                interval: yInterval,
                getTitlesWidget: (value, meta) {
                  if (value == meta.min || value == meta.max) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(
                      '${value.toInt()}°',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: Color(0xFF94A3B8),
                        fontSize: 11,
                      ),
                    ),
                  );
                },
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 34,
                interval: 6,
                getTitlesWidget: (value, meta) {
                  if (value == meta.min || value == meta.max) {
                    return const SizedBox.shrink();
                  }
                  final dtLocal = reftime
                      .add(Duration(minutes: (value * 60).round()))
                      .toLocal();
                  final isMidnight = dtLocal.hour < 6 && value > 0;
                  final label = isMidnight
                      ? DateFormat('E\nHH:mm').format(dtLocal)
                      : DateFormat('HH:mm').format(dtLocal);
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFF94A3B8),
                        fontSize: 10,
                        height: 1.15,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            handleBuiltInTouches: true,
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => const Color(0xFF0F172A).withValues(alpha: 0.94),
              tooltipBorder: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
              tooltipBorderRadius: BorderRadius.circular(10),
              fitInsideHorizontally: true,
              fitInsideVertically: true,
              getTooltipItems: (touchedSpots) {
                if (touchedSpots.isEmpty) return [];
                final x = touchedSpots.first.x;
                final dtLocal = reftime
                    .add(Duration(minutes: (x * 60).round()))
                    .toLocal();
                final timeLabel = DateFormat('EEE HH:mm').format(dtLocal);

                return touchedSpots.asMap().entries.map((entry) {
                  final i = entry.key;
                  final spot = entry.value;
                  final bIdx = spot.barIndex;
                  if (bIdx == p10Idx || bIdx == p90Idx) {
                    return null;
                  }

                  String prefix;
                  Color color;
                  if (bIdx == schoebBarIdx) {
                    prefix = 'Schoebcast';
                    color = const Color(0xFF2DD4BF);
                  } else if (bIdx == iconMeanBarIdx) {
                    prefix = 'Raw ICON';
                    color = const Color(0xFF60A5FA);
                  } else if (bIdx == liveBarIdx) {
                    prefix = 'Live KLO';
                    color = const Color(0xFFF8FAFC);
                  } else if (bIdx == lookbackBarIdx) {
                    prefix = 'Observed';
                    color = const Color(0xFFCBD5E1);
                  } else {
                    return null;
                  }

                  final header = i == 0 ? '$timeLabel\n' : '';
                  return LineTooltipItem(
                    '$header$prefix: ${spot.y.toStringAsFixed(1)} °C',
                    TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  );
                }).toList();
              },
            ),
          ),
        ),
      ),
    );
  }
}
