import 'package:tapxr_debug/ble/tap_constants.dart';

enum TapEventType { tap, gesture, mouse, raw, mode, info }

class TapEvent {
  final DateTime timestamp;
  final TapEventType type;
  final String label;
  final String detail;
  final int? code;

  TapEvent({
    required this.type,
    required this.label,
    required this.detail,
    this.code,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  String get timeString {
    final t = timestamp;
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
  }

  /// Create a tap event from raw BLE data.
  factory TapEvent.fromTapData(List<int> data) {
    final code = data[0];
    final char = defaultTapMap[code] ?? '?';
    final charDisplay = char == ' ' ? 'SPACE' : char;
    return TapEvent(
      type: TapEventType.tap,
      label: 'TAP',
      detail: '${fingersDisplay(code)}  →  $charDisplay',
      code: code,
    );
  }

  /// Create a gesture event from raw BLE data.
  factory TapEvent.fromGestureData(List<int> data) {
    if (data[0] == 0x14) {
      final mode = mouseModeNames[data[1]] ?? 'UNKNOWN(${data[1]})';
      return TapEvent(
        type: TapEventType.mode,
        label: 'MODE',
        detail: 'mouse_mode → $mode',
      );
    }
    final code = data[0];
    final name = airGestureNames[code] ?? 'UNKNOWN($code)';
    return TapEvent(
      type: TapEventType.gesture,
      label: 'GEST',
      detail: name,
      code: code,
    );
  }

  /// Create a mouse event from raw BLE data.
  factory TapEvent.fromMouseData(List<int> data) {
    int int16(int offset) {
      final val = data[offset] | (data[offset + 1] << 8);
      return val >= 0x8000 ? val - 0x10000 : val;
    }

    final vx = int16(1);
    final vy = int16(3);
    final prox = data.length > 9 && data[9] == 1;
    return TapEvent(
      type: TapEventType.mouse,
      label: 'MOUSE',
      detail: 'vx=${_signed(vx)}  vy=${_signed(vy)}  proximity=$prox',
    );
  }

  /// Create an info event (connection status, etc).
  factory TapEvent.info(String message) {
    return TapEvent(
      type: TapEventType.info,
      label: 'INFO',
      detail: message,
    );
  }

  static String _signed(int v) => v >= 0 ? '+$v' : '$v';
}

/// Session statistics tracker.
class SessionStats {
  int tapCount = 0;
  int gestureCount = 0;
  int mouseEvents = 0;
  int rawPackets = 0;
  final Map<int, int> tapCodes = {};
  final Map<int, int> gestureCodes = {};
  final DateTime startTime = DateTime.now();

  Duration get elapsed => DateTime.now().difference(startTime);

  double get tapsPerMinute {
    final secs = elapsed.inSeconds;
    if (secs < 1) return 0;
    return tapCount / (secs / 60);
  }

  void recordTap(int code) {
    tapCount++;
    tapCodes[code] = (tapCodes[code] ?? 0) + 1;
  }

  void recordGesture(int code) {
    gestureCount++;
    gestureCodes[code] = (gestureCodes[code] ?? 0) + 1;
  }

  void recordMouse() => mouseEvents++;
  void recordRaw([int count = 1]) => rawPackets += count;

  void reset() {
    tapCount = 0;
    gestureCount = 0;
    mouseEvents = 0;
    rawPackets = 0;
    tapCodes.clear();
    gestureCodes.clear();
  }
}
