import 'package:flutter/material.dart';
import 'package:tapxr_debug/ble/tap_constants.dart';

class ReferenceScreen extends StatelessWidget {
  const ReferenceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tap Code Reference'),
        backgroundColor: Colors.grey[900],
        foregroundColor: Colors.white,
      ),
      backgroundColor: Colors.black,
      body: ListView.builder(
        itemCount: 31,
        padding: const EdgeInsets.all(8),
        itemBuilder: (context, index) {
          final code = index + 1;
          final bits = tapcodeToFingers(code);
          final active = <String>[];
          for (var i = 0; i < 5; i++) {
            if (bits[i]) active.add(fingerNames[i]);
          }
          final char = defaultTapMap[code] ?? '?';
          final charDisplay = char == ' ' ? 'SPACE' : char;

          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Colors.grey[800]!, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                // Code number
                SizedBox(
                  width: 32,
                  child: Text(
                    '$code',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontFamily: 'monospace',
                      fontSize: 14,
                    ),
                  ),
                ),
                // Finger visual
                SizedBox(
                  width: 100,
                  child: _FingerVisual(bits: bits),
                ),
                const SizedBox(width: 12),
                // Character
                Container(
                  width: 44,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.blue[900],
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    charDisplay,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Finger names
                Expanded(
                  child: Text(
                    active.join(' + '),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Visual representation of which fingers are active.
class _FingerVisual extends StatelessWidget {
  final List<bool> bits;
  const _FingerVisual({required this.bits});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        final active = bits[i];
        return Container(
          width: 16,
          height: 24,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: active ? Colors.greenAccent : Colors.grey[800],
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: Text(
            fingerShort[i],
            style: TextStyle(
              color: active ? Colors.black : Colors.grey[600],
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
      }),
    );
  }
}
