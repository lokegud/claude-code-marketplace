#!/usr/bin/env python3
"""
TapXR Gesture Debug Tool

Connects to a paired TapXR device over BLE and displays all incoming
gesture, tap, mouse, and raw-sensor data in real time. Helps diagnose
why taps are not being registered by showing exactly what the device
reports at the Bluetooth level.

Requirements:
    pip install bleak

Usage:
    python tapxr_debug.py                  # auto-detect paired TapXR
    python tapxr_debug.py --address AA:BB:CC:DD:EE:FF   # specific MAC
    python tapxr_debug.py --raw            # also stream raw sensor data
    python tapxr_debug.py --duration 60    # run for 60 seconds then exit
"""

import argparse
import asyncio
import platform
import signal
import sys
import time
from collections import Counter, deque
from datetime import datetime

try:
    from bleak import BleakClient, BleakScanner
except ImportError:
    print("ERROR: 'bleak' is required.  Install with:  pip install bleak")
    sys.exit(1)


# ── TapXR BLE UUIDs ────────────────────────────────────────────────
TAP_SERVICE            = "c3ff0001-1d8b-40fd-a56f-c7bd5d0f3370"
TAP_DATA_CHAR          = "c3ff0005-1d8b-40fd-a56f-c7bd5d0f3370"
MOUSE_DATA_CHAR        = "c3ff0006-1d8b-40fd-a56f-c7bd5d0f3370"
AIR_GESTURE_DATA_CHAR  = "c3ff000a-1d8b-40fd-a56f-c7bd5d0f3370"
UI_CMD_CHAR            = "c3ff0009-1d8b-40fd-a56f-c7bd5d0f3370"
NUS_RX_CHAR            = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"  # mode writes
NUS_TX_CHAR            = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"  # raw sensor


# ── Input mode commands ─────────────────────────────────────────────
MODE_TEXT            = bytearray([0x03, 0x0C, 0x00, 0x00])
MODE_CONTROLLER      = bytearray([0x03, 0x0C, 0x00, 0x01])
MODE_CONTROLLER_TEXT = bytearray([0x03, 0x0C, 0x00, 0x03])


def raw_mode_command(sensitivity=None):
    """Build a raw-sensor mode command with optional sensitivity."""
    if sensitivity is None:
        sensitivity = [0, 0, 0]
    s = [max(0, min(4, sensitivity[0])),   # finger accelerometers  0-4
         max(0, min(5, sensitivity[1])),   # IMU gyro               0-5
         max(0, min(4, sensitivity[2]))]   # IMU accelerometer      0-4
    return bytearray([0x03, 0x0C, 0x00, 0x0A]) + bytearray(s)


# ── Finger / tap-code helpers ──────────────────────────────────────
FINGER_NAMES = ["Thumb", "Index", "Middle", "Ring", "Pinky"]
FINGER_SHORT = ["T", "I", "M", "R", "P"]

# Default TapXR character map (TapAlpha v1 layout).
# Keyed by tap-code (1-31).  Not every code maps to a printable char.
DEFAULT_TAP_MAP = {
    # ── single-finger vowels ──
    1:  "a",   # Thumb
    2:  "e",   # Index
    4:  "i",   # Middle
    8:  "o",   # Ring
    16: "u",   # Pinky
    # ── two-finger consonants (most common letters first) ──
    3:  "t",   # Thumb + Index
    5:  "n",   # Thumb + Middle
    9:  "s",   # Thumb + Ring
    17: "h",   # Thumb + Pinky
    6:  "r",   # Index + Middle
    10: "d",   # Index + Ring
    18: "c",   # Index + Pinky
    12: "l",   # Middle + Ring
    20: "w",   # Middle + Pinky
    24: "f",   # Ring + Pinky
    # ── three-finger combos ──
    7:  "m",   # Thumb + Index + Middle
    11: "b",   # Thumb + Index + Ring
    19: "p",   # Thumb + Index + Pinky
    13: "v",   # Thumb + Middle + Ring
    21: "g",   # Thumb + Middle + Pinky
    25: "y",   # Thumb + Ring + Pinky
    14: "x",   # Index + Middle + Ring
    22: "j",   # Index + Middle + Pinky
    26: "k",   # Index + Ring + Pinky
    28: "q",   # Middle + Ring + Pinky
    # ── four-finger combos ──
    15: "z",   # Thumb + Index + Middle + Ring
    23: ".",   # Thumb + Index + Middle + Pinky
    27: ",",   # Thumb + Index + Ring + Pinky
    29: "?",   # Thumb + Middle + Ring + Pinky
    30: "!",   # Index + Middle + Ring + Pinky
    # ── all five fingers ──
    31: " ",   # Space
}


def tapcode_to_fingers(code: int) -> list[bool]:
    """Convert a 5-bit tap-code to a list of per-finger booleans."""
    return [bool(code & (1 << i)) for i in range(5)]


def fingers_display(code: int) -> str:
    """Return a compact visual like [T . M . P] showing active fingers."""
    bits = tapcode_to_fingers(code)
    parts = [FINGER_SHORT[i] if bits[i] else "." for i in range(5)]
    return "[" + " ".join(parts) + "]"


def tapcode_label(code: int) -> str:
    """Human-readable label for a tap code."""
    bits = tapcode_to_fingers(code)
    active = [FINGER_NAMES[i] for i in range(5) if bits[i]]
    char = DEFAULT_TAP_MAP.get(code, "?")
    char_display = repr(char) if char == " " else char
    return f"code={code:2d}  {fingers_display(code)}  fingers={'+'.join(active):<30s}  char={char_display}"


# ── Air-gesture labels ──────────────────────────────────────────────
AIR_GESTURE_NAMES = {
    0:   "NONE",
    1:   "GENERAL",
    2:   "UP_ONE_FINGER",
    3:   "UP_TWO_FINGERS",
    4:   "DOWN_ONE_FINGER",
    5:   "DOWN_TWO_FINGERS",
    6:   "LEFT_ONE_FINGER",
    7:   "LEFT_TWO_FINGERS",
    8:   "RIGHT_ONE_FINGER",
    9:   "RIGHT_TWO_FINGERS",
    10:  "PINCH",
    12:  "THUMB_INDEX",
    14:  "THUMB_MIDDLE",
    100: "STATE_OPEN",
    101: "STATE_THUMB_INDEX",
    102: "STATE_THUMB_MIDDLE",
}

MOUSE_MODE_NAMES = {0: "STANDBY", 1: "AIR_MOUSE", 2: "OPTICAL1", 3: "OPTICAL2"}

MSG_TYPE_BIT = 2**31


# ── Raw-sensor parser ──────────────────────────────────────────────
def parse_raw_data(data: bytearray) -> list[dict]:
    """Parse a raw-sensor BLE notification into timestamped messages."""
    messages = []
    ptr = 0
    length = len(data)
    while ptr + 4 <= length:
        ts = int.from_bytes(data[ptr:ptr+4], "little", signed=False)
        if ts == 0:
            break
        ptr += 4
        if ts > MSG_TYPE_BIT:
            msg_type = "accel"
            ts -= MSG_TYPE_BIT
            n_samples = 15   # 5 fingers x 3 axes
        else:
            msg_type = "imu"
            n_samples = 6    # gyro(3) + accel(3)
        payload = []
        for _ in range(n_samples):
            if ptr + 2 > length:
                break
            payload.append(int.from_bytes(data[ptr:ptr+2], "little", signed=True))
            ptr += 2
        messages.append({"type": msg_type, "ts": ts, "payload": payload})
    return messages


# ── Statistics tracker ──────────────────────────────────────────────
class Stats:
    def __init__(self):
        self.tap_count = 0
        self.tap_codes = Counter()
        self.gesture_count = 0
        self.gesture_codes = Counter()
        self.mouse_events = 0
        self.raw_packets = 0
        self.start_time = time.monotonic()
        self.tap_times = deque(maxlen=200)  # recent tap timestamps

    def record_tap(self, code):
        self.tap_count += 1
        self.tap_codes[code] += 1
        self.tap_times.append(time.monotonic())

    def record_gesture(self, code):
        self.gesture_count += 1
        self.gesture_codes[code] += 1

    def record_mouse(self):
        self.mouse_events += 1

    def record_raw(self, count=1):
        self.raw_packets += count

    @property
    def elapsed(self):
        return time.monotonic() - self.start_time

    @property
    def taps_per_minute(self):
        if self.elapsed < 1:
            return 0.0
        return self.tap_count / (self.elapsed / 60)

    def summary(self) -> str:
        lines = [
            "",
            "=" * 70,
            "  SESSION SUMMARY",
            "=" * 70,
            f"  Duration         : {self.elapsed:.1f}s",
            f"  Total taps       : {self.tap_count}   ({self.taps_per_minute:.1f} taps/min)",
            f"  Total gestures   : {self.gesture_count}",
            f"  Mouse events     : {self.mouse_events}",
            f"  Raw packets      : {self.raw_packets}",
        ]

        if self.tap_codes:
            lines.append("")
            lines.append("  TAP CODE DISTRIBUTION (most common first):")
            lines.append("  " + "-" * 66)
            for code, count in self.tap_codes.most_common(15):
                bar = "#" * min(count, 40)
                lines.append(f"    {tapcode_label(code)}  x{count:3d}  {bar}")

        if self.gesture_codes:
            lines.append("")
            lines.append("  AIR GESTURE DISTRIBUTION:")
            lines.append("  " + "-" * 66)
            for code, count in self.gesture_codes.most_common(10):
                name = AIR_GESTURE_NAMES.get(code, f"UNKNOWN({code})")
                lines.append(f"    {name:<28s}  x{count}")

        lines.append("=" * 70)
        return "\n".join(lines)


# ── BLE notification handlers ──────────────────────────────────────
def make_tap_handler(stats: Stats):
    def handler(_sender, data: bytearray):
        code = data[0]
        stats.record_tap(code)
        ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
        print(f"  [{ts}]  TAP   {tapcode_label(code)}")
    return handler


def make_gesture_handler(stats: Stats):
    def handler(_sender, data: bytearray):
        if data[0] == 0x14:   # mouse-mode state change
            mode = MOUSE_MODE_NAMES.get(data[1], f"UNKNOWN({data[1]})")
            ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
            print(f"  [{ts}]  MODE  mouse_mode -> {mode}")
            return
        code = data[0]
        stats.record_gesture(code)
        name = AIR_GESTURE_NAMES.get(code, f"UNKNOWN({code})")
        ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
        print(f"  [{ts}]  GEST  {name}")
    return handler


def make_mouse_handler(stats: Stats):
    def handler(_sender, data: bytearray):
        stats.record_mouse()
        vx = int.from_bytes(data[1:3], "little", signed=True)
        vy = int.from_bytes(data[3:5], "little", signed=True)
        prox = data[9] == 1 if len(data) > 9 else False
        ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
        print(f"  [{ts}]  MOUSE vx={vx:+5d}  vy={vy:+5d}  proximity={prox}")
    return handler


def make_raw_handler(stats: Stats):
    def handler(_sender, data: bytearray):
        msgs = parse_raw_data(data)
        stats.record_raw(len(msgs))
        for m in msgs:
            ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
            if m["type"] == "imu":
                p = m["payload"]
                if len(p) >= 6:
                    print(f"  [{ts}]  IMU   ts={m['ts']:8d}ms  "
                          f"gyro=({p[0]:+6d},{p[1]:+6d},{p[2]:+6d})  "
                          f"accel=({p[3]:+6d},{p[4]:+6d},{p[5]:+6d})")
            else:
                p = m["payload"]
                parts = []
                for f in range(5):
                    off = f * 3
                    if off + 2 < len(p):
                        parts.append(f"{FINGER_SHORT[f]}=({p[off]:+6d},{p[off+1]:+6d},{p[off+2]:+6d})")
                print(f"  [{ts}]  ACCEL ts={m['ts']:8d}ms  {' '.join(parts)}")
    return handler


# ── Device discovery ────────────────────────────────────────────────
async def find_tap_device(address: str | None = None) -> str:
    """Scan for a paired TapXR / Tap Strap device."""
    if address:
        return address

    # On Linux, try bt-device first (works with paired devices)
    if platform.system() == "Linux":
        import subprocess
        try:
            result = subprocess.run(
                ["bt-device", "--list"],
                capture_output=True, text=True, timeout=5
            )
            if result.returncode == 0:
                for line in result.stdout.splitlines():
                    if line.lower().startswith("tap"):
                        # Format: "Tap_XXXX (AA:BB:CC:DD:EE:FF)"
                        mac = line.strip()[-18:-1]
                        if ":" in mac:
                            print(f"  Found paired Tap device: {line.strip()}")
                            return mac
        except (FileNotFoundError, subprocess.TimeoutExpired):
            pass

    print("  Scanning for Tap devices (5s) ...")
    devices = await BleakScanner.discover(timeout=5.0)
    for d in devices:
        name = d.name or ""
        if name.lower().startswith("tap"):
            print(f"  Found: {d.name} [{d.address}]")
            return d.address

    print("  ERROR: No Tap device found.")
    print("  Make sure your TapXR is paired and connected via Bluetooth,")
    print("  or specify the address with --address AA:BB:CC:DD:EE:FF")
    sys.exit(1)


# ── Reference table ─────────────────────────────────────────────────
def print_tap_reference():
    """Print the full tap-code → character reference table."""
    print()
    print("=" * 70)
    print("  TAPXR DEFAULT CHARACTER MAP (TapAlpha v1)")
    print("=" * 70)
    print(f"  {'Code':<6} {'Fingers':<13} {'Active':<30} {'Char'}")
    print("  " + "-" * 66)
    for code in range(1, 32):
        bits = tapcode_to_fingers(code)
        active = "+".join(FINGER_NAMES[i] for i in range(5) if bits[i])
        char = DEFAULT_TAP_MAP.get(code, "?")
        char_display = repr(char) if char == " " else char
        print(f"  {code:<6d} {fingers_display(code):<13} {active:<30} {char_display}")
    print("=" * 70)
    print()


# ── Main ────────────────────────────────────────────────────────────
async def run(args):
    stats = Stats()
    stop_event = asyncio.Event()

    def on_signal():
        stop_event.set()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, on_signal)
        except NotImplementedError:
            # Windows doesn't support add_signal_handler
            pass

    if args.reference:
        print_tap_reference()
        return

    print()
    print("  TapXR Gesture Debug Tool")
    print("  " + "-" * 40)

    address = await find_tap_device(args.address)
    print(f"  Connecting to {address} ...")

    async with BleakClient(address) as client:
        if not client.is_connected:
            print("  ERROR: Failed to connect.")
            return

        print(f"  Connected!  (BLE MTU negotiated)")
        print()

        # Subscribe to tap, gesture, and mouse notifications
        await client.start_notify(TAP_DATA_CHAR, make_tap_handler(stats))
        await client.start_notify(AIR_GESTURE_DATA_CHAR, make_gesture_handler(stats))
        await client.start_notify(MOUSE_DATA_CHAR, make_mouse_handler(stats))

        if args.raw:
            await client.start_notify(NUS_TX_CHAR, make_raw_handler(stats))

        # Set controller mode so tap events are sent over BLE
        mode = MODE_CONTROLLER_TEXT if args.text else MODE_CONTROLLER
        if args.raw:
            mode = raw_mode_command(args.sensitivity)
        await client.write_gatt_char(NUS_RX_CHAR, mode)

        mode_name = "raw" if args.raw else ("controller+text" if args.text else "controller")
        print(f"  Mode set to: {mode_name}")
        print(f"  Listening for events ... (Ctrl+C to stop)")
        print("  " + "-" * 60)
        print()

        # Keep-alive: the Tap reverts to text mode after ~10s without
        # a mode refresh, so re-send the command periodically.
        async def keepalive():
            while not stop_event.is_set():
                await asyncio.sleep(8)
                if client.is_connected:
                    try:
                        await client.write_gatt_char(NUS_RX_CHAR, mode)
                    except Exception:
                        pass

        keepalive_task = asyncio.create_task(keepalive())

        # Run until duration elapsed or Ctrl+C
        try:
            if args.duration:
                await asyncio.wait_for(stop_event.wait(), timeout=args.duration)
            else:
                await stop_event.wait()
        except asyncio.TimeoutError:
            pass
        except KeyboardInterrupt:
            pass
        finally:
            stop_event.set()
            keepalive_task.cancel()
            try:
                await keepalive_task
            except asyncio.CancelledError:
                pass

        # Restore text mode before disconnecting
        try:
            await client.write_gatt_char(NUS_RX_CHAR, MODE_TEXT)
        except Exception:
            pass

    print(stats.summary())


def main():
    parser = argparse.ArgumentParser(
        description="TapXR Gesture Debug Tool — see exactly what your Tap device registers",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
examples:
  %(prog)s                        auto-detect and listen for taps
  %(prog)s --address AA:BB:CC:DD:EE:FF   use a specific device
  %(prog)s --raw                  include raw accelerometer/IMU data
  %(prog)s --duration 30          run for 30 seconds then print summary
  %(prog)s --reference            print the tap-code character map and exit
"""
    )
    parser.add_argument("--address", "-a",
                        help="BLE MAC address of the Tap device (auto-detected if omitted)")
    parser.add_argument("--raw", "-r", action="store_true",
                        help="also stream raw accelerometer + IMU sensor data")
    parser.add_argument("--text", "-t", action="store_true",
                        help="use controller+text mode (Tap also types normally)")
    parser.add_argument("--duration", "-d", type=float, default=None,
                        help="stop after N seconds (default: run until Ctrl+C)")
    parser.add_argument("--sensitivity", "-s", type=int, nargs=3,
                        default=[0, 0, 0], metavar=("FINGER", "GYRO", "ACCEL"),
                        help="raw-mode sensitivity [finger:0-4  gyro:0-5  accel:0-4]")
    parser.add_argument("--reference", action="store_true",
                        help="print the full tap-code → character reference table and exit")
    args = parser.parse_args()

    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
