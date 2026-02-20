import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

/// TapXR BLE service and characteristic UUIDs.
class TapUuids {
  static final service = Uuid.parse('c3ff0001-1d8b-40fd-a56f-c7bd5d0f3370');
  static final tapData = Uuid.parse('c3ff0005-1d8b-40fd-a56f-c7bd5d0f3370');
  static final mouseData = Uuid.parse('c3ff0006-1d8b-40fd-a56f-c7bd5d0f3370');
  static final airGesture = Uuid.parse('c3ff000a-1d8b-40fd-a56f-c7bd5d0f3370');
  static final uiCmd = Uuid.parse('c3ff0009-1d8b-40fd-a56f-c7bd5d0f3370');
  static final nusRx = Uuid.parse('6e400002-b5a3-f393-e0a9-e50e24dcca9e');
  static final nusTx = Uuid.parse('6e400003-b5a3-f393-e0a9-e50e24dcca9e');

  /// NUS service (Nordic UART) for mode writes / raw sensor.
  static final nusService = Uuid.parse('6e400001-b5a3-f393-e0a9-e50e24dcca9e');
}

/// Input mode command bytes sent via NUS RX.
class TapModes {
  static const text = [0x03, 0x0C, 0x00, 0x00];
  static const controller = [0x03, 0x0C, 0x00, 0x01];
  static const controllerText = [0x03, 0x0C, 0x00, 0x03];

  static List<int> raw({List<int>? sensitivity}) {
    final s = sensitivity ?? [0, 0, 0];
    return [
      0x03, 0x0C, 0x00, 0x0A,
      s[0].clamp(0, 4), // finger accelerometers 0-4
      s[1].clamp(0, 5), // IMU gyro 0-5
      s[2].clamp(0, 4), // IMU accelerometer 0-4
    ];
  }
}

/// Finger names and short labels.
const fingerNames = ['Thumb', 'Index', 'Middle', 'Ring', 'Pinky'];
const fingerShort = ['T', 'I', 'M', 'R', 'P'];

/// Default TapXR character map (TapAlpha v1).
const defaultTapMap = <int, String>{
  // single-finger vowels
  1: 'a', 2: 'e', 4: 'i', 8: 'o', 16: 'u',
  // two-finger consonants
  3: 't', 5: 'n', 9: 's', 17: 'h', 6: 'r',
  10: 'd', 18: 'c', 12: 'l', 20: 'w', 24: 'f',
  // three-finger combos
  7: 'm', 11: 'b', 19: 'p', 13: 'v', 21: 'g',
  25: 'y', 14: 'x', 22: 'j', 26: 'k', 28: 'q',
  // four-finger combos
  15: 'z', 23: '.', 27: ',', 29: '?', 30: '!',
  // all five fingers
  31: ' ',
};

/// Air gesture code names.
const airGestureNames = <int, String>{
  0: 'NONE',
  1: 'GENERAL',
  2: 'UP_ONE_FINGER',
  3: 'UP_TWO_FINGERS',
  4: 'DOWN_ONE_FINGER',
  5: 'DOWN_TWO_FINGERS',
  6: 'LEFT_ONE_FINGER',
  7: 'LEFT_TWO_FINGERS',
  8: 'RIGHT_ONE_FINGER',
  9: 'RIGHT_TWO_FINGERS',
  10: 'PINCH',
  12: 'THUMB_INDEX',
  14: 'THUMB_MIDDLE',
  100: 'STATE_OPEN',
  101: 'STATE_THUMB_INDEX',
  102: 'STATE_THUMB_MIDDLE',
};

const mouseModeNames = <int, String>{
  0: 'STANDBY',
  1: 'AIR_MOUSE',
  2: 'OPTICAL1',
  3: 'OPTICAL2',
};

/// Convert a 5-bit tap code to per-finger booleans.
List<bool> tapcodeToFingers(int code) {
  return List.generate(5, (i) => (code & (1 << i)) != 0);
}

/// Compact visual like [T . M . P] showing active fingers.
String fingersDisplay(int code) {
  final bits = tapcodeToFingers(code);
  final parts = List.generate(5, (i) => bits[i] ? fingerShort[i] : '.');
  return '[${parts.join(' ')}]';
}

/// Human-readable label for a tap code.
String tapcodeLabel(int code) {
  final bits = tapcodeToFingers(code);
  final active = <String>[];
  for (var i = 0; i < 5; i++) {
    if (bits[i]) active.add(fingerNames[i]);
  }
  final char = defaultTapMap[code] ?? '?';
  final charDisplay = char == ' ' ? 'SPACE' : char;
  return '${fingersDisplay(code)}  ${active.join('+')}  →  $charDisplay';
}
