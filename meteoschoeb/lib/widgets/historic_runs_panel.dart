import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/weather_models.dart';
import '../services/weather_service.dart';
import 'temperature_forecast_card.dart';

class HistoricRunsPanel extends StatefulWidget {
  const HistoricRunsPanel({
    super.key,
    required this.service,
    required this.runs,
    required this.latestForecast,
  });

  final WeatherService service;
  final List<HistoryRunEntry> runs;
  final KloForecast latestForecast;

  @override
  State<HistoricRunsPanel> createState() => _HistoricRunsPanelState();
}

class _HistoricRunsPanelState extends State<HistoricRunsPanel> {
  final Map<String, KloForecast> _cache = {};
  HistoryRunEntry? _selected;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initSelection();
  }

  @override
  void didUpdateWidget(covariant HistoricRunsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runs != widget.runs) {
      _initSelection();
    }
  }

  void _initSelection() {
    if (widget.runs.isEmpty) {
      _selected = null;
      return;
    }
    // Cache the already-loaded latest forecast under its reftime key
    _cache[widget.latestForecast.reftime.toIso8601String()] = widget.latestForecast;

    // Default to the second run (first historic run) if available, else the first
    final initial = widget.runs.length > 1 ? widget.runs[1] : widget.runs.first;
    _selectRun(initial);
  }

  Future<void> _selectRun(HistoryRunEntry entry) async {
    final key = entry.reftime.toIso8601String();
    setState(() {
      _selected = entry;
      _error = null;
      _loading = !_cache.containsKey(key);
    });

    if (_cache.containsKey(key)) return;

    try {
      final loaded = await widget.service.fetchRunForecast(entry);
      if (!mounted) return;
      setState(() {
        _cache[key] = loaded;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  String _formatRunLabel(HistoryRunEntry entry) {
    final dtUtc = entry.reftime;
    final dateStr = DateFormat('EEE dd MMM • HH:mm').format(dtUtc);
    final ver = entry.verifiedHours > 0 ? ' (${entry.verifiedHours}h obs)' : '';
    return '$dateStr UTC$ver';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.runs.isEmpty) {
      return const SizedBox.shrink();
    }

    final selected = _selected ?? widget.runs.first;
    final forecast = _cache[selected.reftime.toIso8601String()];

    return TemperatureForecastCard(
      title: 'Historic Runs',
      forecast: forecast,
      isLoading: _loading,
      controls: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<HistoryRunEntry>(
                    value: selected,
                    dropdownColor: const Color(0xFF0F172A),
                    iconEnabledColor: const Color(0xFF94A3B8),
                    isDense: true,
                    style: const TextStyle(
                      color: Color(0xFFE2E8F0),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                    items: widget.runs
                        .map(
                          (r) => DropdownMenuItem<HistoryRunEntry>(
                            value: r,
                            child: Text(_formatRunLabel(r)),
                          ),
                        )
                        .toList(),
                    onChanged: (next) {
                      if (next != null) _selectRun(next);
                    },
                  ),
                ),
              ),
              if (selected.maeSchoebcast != null && selected.maeIcon != null)
                _maeBadge(selected),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              'Could not load run: $_error',
              style: const TextStyle(color: Color(0xFFF87171), fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _maeBadge(HistoryRunEntry entry) {
    final sc = entry.maeSchoebcast!;
    final ic = entry.maeIcon!;
    final scWins = sc <= ic;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: (scWins ? const Color(0xFF2DD4BF) : const Color(0xFF60A5FA))
            .withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: (scWins ? const Color(0xFF2DD4BF) : const Color(0xFF60A5FA))
              .withValues(alpha: 0.35),
        ),
      ),
      child: Text(
        'MAE (${entry.verifiedHours}h): Schoebcast ${sc.toStringAsFixed(2)}° vs ICON ${ic.toStringAsFixed(2)}°',
        style: TextStyle(
          color: scWins ? const Color(0xFF2DD4BF) : const Color(0xFF93C5FD),
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
