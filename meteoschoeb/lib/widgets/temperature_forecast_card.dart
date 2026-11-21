import 'package:flutter/material.dart';

import '../models/weather_models.dart';
import 'forecast_chart.dart';

class TemperatureForecastCard extends StatefulWidget {
  const TemperatureForecastCard({
    super.key,
    required this.title,
    required this.forecast,
    this.liveObservations = const [],
    this.controls,
    this.isLoading = false,
  });

  final String title;
  final KloForecast? forecast;
  final List<LiveObservation> liveObservations;
  final Widget? controls;
  final bool isLoading;

  @override
  State<TemperatureForecastCard> createState() => _TemperatureForecastCardState();
}

class _TemperatureForecastCardState extends State<TemperatureForecastCard> {
  bool _showRawIcon = true;
  bool _showSpread = true;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 18, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
            if (widget.controls != null) ...[
              const SizedBox(height: 12),
              widget.controls!,
            ],
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
                _legendItem(const Color(0xFFF8FAFC), 'Actual KLO'),
              ],
            ),
            const SizedBox(height: 16),
            if (widget.isLoading || widget.forecast == null)
              const SizedBox(
                height: 250,
                child: Center(
                  child: CircularProgressIndicator(color: Color(0xFF2DD4BF)),
                ),
              )
            else
              ForecastChart(
                forecast: widget.forecast!,
                liveObservations: widget.liveObservations,
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
}
