import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tapxr_debug/ble/tap_ble_manager.dart' as ble;
import 'package:tapxr_debug/models/tap_event.dart';
import 'package:tapxr_debug/screens/reference_screen.dart';
import 'package:tapxr_debug/screens/stats_screen.dart';

class DebugScreen extends StatelessWidget {
  const DebugScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ble.TapBleManager>(
      builder: (context, manager, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('TapXR Debug'),
            backgroundColor: Colors.grey[900],
            foregroundColor: Colors.white,
            actions: [
              // Stats button
              IconButton(
                icon: const Icon(Icons.bar_chart),
                tooltip: 'Session Stats',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const StatsScreen()),
                ),
              ),
              // Reference table button
              IconButton(
                icon: const Icon(Icons.table_chart),
                tooltip: 'Tap Code Reference',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ReferenceScreen()),
                ),
              ),
              // Clear log
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Clear Log',
                onPressed: manager.clearEvents,
              ),
            ],
          ),
          body: Column(
            children: [
              _ConnectionBar(manager: manager),
              _ModeBar(manager: manager),
              Expanded(child: _EventLog(events: manager.events)),
            ],
          ),
        );
      },
    );
  }
}

/// Top bar showing connection status and scan/connect/disconnect button.
class _ConnectionBar extends StatelessWidget {
  final ble.TapBleManager manager;
  const _ConnectionBar({required this.manager});

  @override
  Widget build(BuildContext context) {
    final state = manager.state;
    final Color statusColor;
    final String statusText;
    final String buttonText;
    final VoidCallback? onPressed;

    switch (state) {
      case ble.ConnectionState.disconnected:
        statusColor = Colors.red;
        statusText = 'Disconnected';
        buttonText = 'SCAN';
        onPressed = manager.startScan;
        break;
      case ble.ConnectionState.scanning:
        statusColor = Colors.orange;
        statusText = 'Scanning...';
        buttonText = 'STOP';
        onPressed = manager.disconnect;
        break;
      case ble.ConnectionState.connecting:
        statusColor = Colors.orange;
        statusText = 'Connecting...';
        buttonText = 'CANCEL';
        onPressed = manager.disconnect;
        break;
      case ble.ConnectionState.connected:
        statusColor = Colors.green;
        statusText = manager.deviceName ?? 'Connected';
        buttonText = 'DISCONNECT';
        onPressed = manager.disconnect;
        break;
    }

    return Container(
      color: Colors.grey[850],
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              statusText,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w500,
                fontSize: 15,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: onPressed,
            style: ElevatedButton.styleFrom(
              backgroundColor: state == ble.ConnectionState.connected
                  ? Colors.red[700]
                  : Colors.blue[700],
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            ),
            child: Text(buttonText),
          ),
        ],
      ),
    );
  }
}

/// Bar with mode toggles (raw, text).
class _ModeBar extends StatelessWidget {
  final ble.TapBleManager manager;
  const _ModeBar({required this.manager});

  @override
  Widget build(BuildContext context) {
    final connected = manager.state == ble.ConnectionState.connected;

    return Container(
      color: Colors.grey[800],
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          const Text('Mode:', style: TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(width: 12),
          _chip('Controller', true, null),
          const SizedBox(width: 8),
          _chip('+ Text', manager.textMode, connected ? manager.toggleText : null),
          const SizedBox(width: 8),
          _chip('+ Raw', manager.rawEnabled, connected ? manager.toggleRaw : null),
          const Spacer(),
          Text(
            '${manager.events.length} events',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, bool active, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active ? Colors.blue[800] : Colors.grey[700],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : Colors.white54,
            fontSize: 12,
            fontWeight: active ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

/// Scrollable event log with color-coded entries.
class _EventLog extends StatefulWidget {
  final List<TapEvent> events;
  const _EventLog({required this.events});

  @override
  State<_EventLog> createState() => _EventLogState();
}

class _EventLogState extends State<_EventLog> {
  final _controller = ScrollController();
  bool _autoScroll = true;

  @override
  void didUpdateWidget(covariant _EventLog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_autoScroll && widget.events.length != oldWidget.events.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_controller.hasClients) {
          _controller.jumpTo(_controller.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is UserScrollNotification) {
          final pos = _controller.position;
          _autoScroll = pos.pixels >= pos.maxScrollExtent - 50;
        }
        return false;
      },
      child: Container(
        color: Colors.black,
        child: widget.events.isEmpty
            ? const Center(
                child: Text(
                  'No events yet.\nTap SCAN to find your TapXR device.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white38, fontSize: 16),
                ),
              )
            : ListView.builder(
                controller: _controller,
                itemCount: widget.events.length,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemBuilder: (context, index) {
                  return _EventRow(event: widget.events[index]);
                },
              ),
      ),
    );
  }
}

/// Single event row in the log.
class _EventRow extends StatelessWidget {
  final TapEvent event;
  const _EventRow({required this.event});

  Color get _labelColor {
    switch (event.type) {
      case TapEventType.tap:
        return Colors.greenAccent;
      case TapEventType.gesture:
        return Colors.cyanAccent;
      case TapEventType.mouse:
        return Colors.amberAccent;
      case TapEventType.raw:
        return Colors.grey;
      case TapEventType.mode:
        return Colors.purpleAccent;
      case TapEventType.info:
        return Colors.white70;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.4),
          children: [
            TextSpan(
              text: event.timeString,
              style: const TextStyle(color: Colors.white38),
            ),
            const TextSpan(text: '  '),
            TextSpan(
              text: event.label.padRight(6),
              style: TextStyle(
                color: _labelColor,
                fontWeight: FontWeight.bold,
              ),
            ),
            TextSpan(
              text: event.detail,
              style: TextStyle(color: _labelColor.withOpacity(0.85)),
            ),
          ],
        ),
      ),
    );
  }
}
