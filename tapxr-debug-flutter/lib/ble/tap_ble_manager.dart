import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:tapxr_debug/ble/tap_constants.dart';
import 'package:tapxr_debug/models/tap_event.dart';

enum ConnectionState { disconnected, scanning, connecting, connected }

/// Manages BLE connection to TapXR device and streams parsed events.
class TapBleManager extends ChangeNotifier {
  final _ble = FlutterReactiveBle();
  final _events = <TapEvent>[];
  final stats = SessionStats();

  ConnectionState _state = ConnectionState.disconnected;
  String? _deviceId;
  String? _deviceName;
  bool _rawEnabled = false;
  bool _textMode = false;

  StreamSubscription? _scanSub;
  StreamSubscription? _connSub;
  final List<StreamSubscription> _notifySubs = [];
  Timer? _keepAlive;

  // Public getters
  ConnectionState get state => _state;
  String? get deviceName => _deviceName;
  List<TapEvent> get events => List.unmodifiable(_events);
  bool get rawEnabled => _rawEnabled;
  bool get textMode => _textMode;

  /// Maximum events to keep in memory.
  static const _maxEvents = 500;

  /// Start scanning for TapXR devices.
  void startScan() {
    _setState(ConnectionState.scanning);
    _addEvent(TapEvent.info('Scanning for TapXR devices...'));

    _scanSub?.cancel();
    _scanSub = _ble.scanForDevices(
      withServices: [TapUuids.service],
      scanMode: ScanMode.lowLatency,
    ).listen(
      (device) {
        final name = device.name;
        if (name.toLowerCase().startsWith('tap')) {
          _addEvent(TapEvent.info('Found: $name [${device.id}]'));
          _scanSub?.cancel();
          connectTo(device.id, name);
        }
      },
      onError: (e) {
        _addEvent(TapEvent.info('Scan error: $e'));
        _setState(ConnectionState.disconnected);
      },
    );

    // Timeout after 10 seconds
    Future.delayed(const Duration(seconds: 10), () {
      if (_state == ConnectionState.scanning) {
        _scanSub?.cancel();
        _addEvent(TapEvent.info(
          'No TapXR device found. Make sure your device is paired and nearby.',
        ));
        _setState(ConnectionState.disconnected);
      }
    });
  }

  /// Connect to a specific device by ID.
  void connectTo(String deviceId, [String? name]) {
    _deviceId = deviceId;
    _deviceName = name;
    _setState(ConnectionState.connecting);
    _addEvent(TapEvent.info('Connecting to ${name ?? deviceId}...'));

    _connSub?.cancel();
    _connSub = _ble
        .connectToDevice(
          id: deviceId,
          connectionTimeout: const Duration(seconds: 10),
        )
        .listen(
          (update) async {
            switch (update.connectionState) {
              case DeviceConnectionState.connected:
                _addEvent(TapEvent.info('Connected!'));
                _setState(ConnectionState.connected);
                await _subscribe();
                break;
              case DeviceConnectionState.disconnected:
                _addEvent(TapEvent.info('Disconnected.'));
                _cleanup();
                _setState(ConnectionState.disconnected);
                break;
              default:
                break;
            }
          },
          onError: (e) {
            _addEvent(TapEvent.info('Connection error: $e'));
            _cleanup();
            _setState(ConnectionState.disconnected);
          },
        );
  }

  /// Subscribe to tap, gesture, and mouse BLE notifications.
  Future<void> _subscribe() async {
    final id = _deviceId;
    if (id == null) return;

    // Subscribe to tap data
    _notifySubs.add(
      _ble
          .subscribeToCharacteristic(QualifiedCharacteristic(
            serviceId: TapUuids.service,
            characteristicId: TapUuids.tapData,
            deviceId: id,
          ))
          .listen((data) {
            if (data.isNotEmpty) {
              final event = TapEvent.fromTapData(data);
              stats.recordTap(data[0]);
              _addEvent(event);
            }
          }),
    );

    // Subscribe to air gesture data
    _notifySubs.add(
      _ble
          .subscribeToCharacteristic(QualifiedCharacteristic(
            serviceId: TapUuids.service,
            characteristicId: TapUuids.airGesture,
            deviceId: id,
          ))
          .listen((data) {
            if (data.isNotEmpty) {
              final event = TapEvent.fromGestureData(data);
              if (event.code != null) stats.recordGesture(event.code!);
              _addEvent(event);
            }
          }),
    );

    // Subscribe to mouse data
    _notifySubs.add(
      _ble
          .subscribeToCharacteristic(QualifiedCharacteristic(
            serviceId: TapUuids.service,
            characteristicId: TapUuids.mouseData,
            deviceId: id,
          ))
          .listen((data) {
            if (data.length >= 5) {
              final event = TapEvent.fromMouseData(data);
              stats.recordMouse();
              _addEvent(event);
            }
          }),
    );

    // Set input mode
    await _sendMode();

    // Keep-alive: re-send mode every 8 seconds
    _keepAlive?.cancel();
    _keepAlive = Timer.periodic(const Duration(seconds: 8), (_) {
      if (_state == ConnectionState.connected) {
        _sendMode();
      }
    });
  }

  /// Subscribe to raw sensor data (NUS TX).
  Future<void> _subscribeRaw() async {
    final id = _deviceId;
    if (id == null) return;

    _notifySubs.add(
      _ble
          .subscribeToCharacteristic(QualifiedCharacteristic(
            serviceId: TapUuids.nusService,
            characteristicId: TapUuids.nusTx,
            deviceId: id,
          ))
          .listen((data) {
            final msgs = _parseRawData(Uint8List.fromList(data));
            stats.recordRaw(msgs.length);
            for (final m in msgs) {
              _addEvent(TapEvent(
                type: TapEventType.raw,
                label: 'RAW',
                detail: m,
              ));
            }
          }),
    );
  }

  /// Toggle raw sensor streaming.
  Future<void> toggleRaw() async {
    _rawEnabled = !_rawEnabled;
    if (_rawEnabled && _state == ConnectionState.connected) {
      await _subscribeRaw();
    }
    await _sendMode();
    notifyListeners();
  }

  /// Toggle text mode.
  Future<void> toggleText() async {
    _textMode = !_textMode;
    await _sendMode();
    notifyListeners();
  }

  /// Send the current input mode command to the device.
  Future<void> _sendMode() async {
    final id = _deviceId;
    if (id == null || _state != ConnectionState.connected) return;

    List<int> mode;
    if (_rawEnabled) {
      mode = TapModes.raw();
    } else if (_textMode) {
      mode = TapModes.controllerText;
    } else {
      mode = TapModes.controller;
    }

    try {
      await _ble.writeCharacteristicWithResponse(
        QualifiedCharacteristic(
          serviceId: TapUuids.nusService,
          characteristicId: TapUuids.nusRx,
          deviceId: id,
        ),
        value: mode,
      );
    } catch (e) {
      // Silently retry on next keep-alive
    }
  }

  /// Disconnect and clean up.
  void disconnect() {
    _addEvent(TapEvent.info('Disconnecting...'));
    // Try to restore text mode before disconnecting
    if (_deviceId != null && _state == ConnectionState.connected) {
      _ble.writeCharacteristicWithResponse(
        QualifiedCharacteristic(
          serviceId: TapUuids.nusService,
          characteristicId: TapUuids.nusRx,
          deviceId: _deviceId!,
        ),
        value: TapModes.text,
      ).catchError((_) {});
    }
    _cleanup();
    _setState(ConnectionState.disconnected);
  }

  /// Clear the event log.
  void clearEvents() {
    _events.clear();
    stats.reset();
    notifyListeners();
  }

  void _addEvent(TapEvent event) {
    _events.add(event);
    if (_events.length > _maxEvents) {
      _events.removeRange(0, _events.length - _maxEvents);
    }
    notifyListeners();
  }

  void _setState(ConnectionState s) {
    _state = s;
    notifyListeners();
  }

  void _cleanup() {
    _keepAlive?.cancel();
    _keepAlive = null;
    for (final sub in _notifySubs) {
      sub.cancel();
    }
    _notifySubs.clear();
    _connSub?.cancel();
    _connSub = null;
    _scanSub?.cancel();
    _scanSub = null;
  }

  /// Parse raw sensor BLE notification into readable strings.
  List<String> _parseRawData(Uint8List data) {
    final messages = <String>[];
    var ptr = 0;
    const msgTypeBit = 1 << 31;

    while (ptr + 4 <= data.length) {
      final tsRaw = data.buffer.asByteData().getUint32(ptr, Endian.little);
      if (tsRaw == 0) break;
      ptr += 4;

      final isAccel = tsRaw > msgTypeBit;
      final ts = isAccel ? tsRaw - msgTypeBit : tsRaw;
      final nSamples = isAccel ? 15 : 6;

      final payload = <int>[];
      for (var i = 0; i < nSamples; i++) {
        if (ptr + 2 > data.length) break;
        payload.add(data.buffer.asByteData().getInt16(ptr, Endian.little));
        ptr += 2;
      }

      if (isAccel) {
        final parts = <String>[];
        for (var f = 0; f < 5; f++) {
          final off = f * 3;
          if (off + 2 < payload.length) {
            parts.add(
              '${fingerShort[f]}=(${payload[off]},${payload[off + 1]},${payload[off + 2]})',
            );
          }
        }
        messages.add('ACCEL ts=${ts}ms ${parts.join(' ')}');
      } else if (payload.length >= 6) {
        messages.add(
          'IMU ts=${ts}ms '
          'gyro=(${payload[0]},${payload[1]},${payload[2]}) '
          'accel=(${payload[3]},${payload[4]},${payload[5]})',
        );
      }
    }
    return messages;
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }
}
