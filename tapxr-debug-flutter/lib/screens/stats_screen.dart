import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tapxr_debug/ble/tap_ble_manager.dart';
import 'package:tapxr_debug/ble/tap_constants.dart';

class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<TapBleManager>(
      builder: (context, manager, _) {
        final stats = manager.stats;
        final elapsed = stats.elapsed;
        final minutes = elapsed.inMinutes;
        final seconds = elapsed.inSeconds % 60;

        // Sort tap codes by frequency
        final tapEntries = stats.tapCodes.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        final gestEntries = stats.gestureCodes.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));

        return Scaffold(
          appBar: AppBar(
            title: const Text('Session Stats'),
            backgroundColor: Colors.grey[900],
            foregroundColor: Colors.white,
          ),
          backgroundColor: Colors.black,
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Overview cards
              _StatCard(
                children: [
                  _StatRow('Duration', '${minutes}m ${seconds}s'),
                  _StatRow('Total Taps', '${stats.tapCount}'),
                  _StatRow('Taps/min', stats.tapsPerMinute.toStringAsFixed(1)),
                  _StatRow('Gestures', '${stats.gestureCount}'),
                  _StatRow('Mouse Events', '${stats.mouseEvents}'),
                  _StatRow('Raw Packets', '${stats.rawPackets}'),
                ],
              ),
              const SizedBox(height: 16),

              // Tap distribution
              if (tapEntries.isNotEmpty) ...[
                const _SectionHeader('Tap Code Distribution'),
                _StatCard(
                  children: tapEntries.take(15).map((e) {
                    final maxCount = tapEntries.first.value;
                    return _BarRow(
                      label: fingersDisplay(e.key),
                      sublabel: defaultTapMap[e.key] == ' '
                          ? 'SPACE'
                          : (defaultTapMap[e.key] ?? '?'),
                      count: e.value,
                      fraction: maxCount > 0 ? e.value / maxCount : 0,
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
              ],

              // Gesture distribution
              if (gestEntries.isNotEmpty) ...[
                const _SectionHeader('Air Gesture Distribution'),
                _StatCard(
                  children: gestEntries.take(10).map((e) {
                    final maxCount = gestEntries.first.value;
                    return _BarRow(
                      label: airGestureNames[e.key] ?? 'UNKNOWN(${e.key})',
                      count: e.value,
                      fraction: maxCount > 0 ? e.value / maxCount : 0,
                    );
                  }).toList(),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final List<Widget> children;
  const _StatCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final String value;
  const _StatRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 14)),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _BarRow extends StatelessWidget {
  final String label;
  final String? sublabel;
  final int count;
  final double fraction;

  const _BarRow({
    required this.label,
    this.sublabel,
    required this.count,
    required this.fraction,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
          if (sublabel != null) ...[
            SizedBox(
              width: 40,
              child: Text(
                sublabel!,
                style: const TextStyle(
                  color: Colors.cyanAccent,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: fraction,
                backgroundColor: Colors.grey[800],
                valueColor: AlwaysStoppedAnimation(Colors.blue[600]!),
                minHeight: 14,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 32,
            child: Text(
              '$count',
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
