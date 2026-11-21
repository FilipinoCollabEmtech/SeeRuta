import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:seeruta/services/wake_word_service.dart';

void main() {
  test('pcm16 is little-endian and scaled to full range', () {
    final bytes = Uint8List.fromList([
      0x00, 0x00, // 0
      0xFF, 0x7F, // 32767
      0x00, 0x80, // -32768
      0x00, 0x40, // 16384
    ]);

    final samples = WakeWordService.pcm16ToFloat32(bytes);

    expect(samples.length, 4);
    expect(samples[0], 0.0);
    expect(samples[1], closeTo(1.0, 1e-4));
    expect(samples[2], -1.0);
    expect(samples[3], closeTo(0.5, 1e-4));
  });

  test('a trailing odd byte is ignored instead of shifting the samples', () {
    final samples = WakeWordService.pcm16ToFloat32(
      Uint8List.fromList([0x00, 0x40, 0x7F]),
    );

    expect(samples.length, 1);
    expect(samples[0], closeTo(0.5, 1e-4));
  });
}
