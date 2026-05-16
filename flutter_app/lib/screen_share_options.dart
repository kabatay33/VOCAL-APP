import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Ekran paylaşımının video kalite ayarları.
///
/// Sistem sesi paylaşımı Windows'ta otomatik olarak yapılır
/// (native WASAPI process-loopback exclusion ile Discord clone'un
/// kendi çıkışı hariç tutulur). Ek bir cihaz seçimi gerekmez.
class ScreenShareOptions {
  final int width;
  final int height;
  final int frameRate;
  final int maxBitrateKbps;

  const ScreenShareOptions({
    this.width = 1920,
    this.height = 1080,
    this.frameRate = 30,
    this.maxBitrateKbps = 5000,
  });

  static const defaults = ScreenShareOptions();

  /// Yaygın çözünürlükler — dropdown için
  static const resolutions = <({int width, int height, String label})>[
    (width: 1280, height: 720, label: '720p (HD)'),
    (width: 1920, height: 1080, label: '1080p (Full HD)'),
    (width: 2560, height: 1440, label: '1440p (2K)'),
    (width: 3840, height: 2160, label: '2160p (4K)'),
  ];

  static const frameRates = <int>[15, 30, 60];

  // Bitrate sınırları (Kbps)
  static const int minBitrateKbps = 500;
  static const int maxBitrateKbpsLimit = 20000;

  ScreenShareOptions copyWith({
    int? width,
    int? height,
    int? frameRate,
    int? maxBitrateKbps,
  }) {
    return ScreenShareOptions(
      width: width ?? this.width,
      height: height ?? this.height,
      frameRate: frameRate ?? this.frameRate,
      maxBitrateKbps: maxBitrateKbps ?? this.maxBitrateKbps,
    );
  }

  Map<String, dynamic> toJson() => {
        'width': width,
        'height': height,
        'frameRate': frameRate,
        'maxBitrateKbps': maxBitrateKbps,
      };

  factory ScreenShareOptions.fromJson(Map<String, dynamic> j) {
    return ScreenShareOptions(
      width: (j['width'] as num?)?.toInt() ?? 1920,
      height: (j['height'] as num?)?.toInt() ?? 1080,
      frameRate: (j['frameRate'] as num?)?.toInt() ?? 30,
      maxBitrateKbps: (j['maxBitrateKbps'] as num?)?.toInt() ?? 5000,
    );
  }

  static const String _kPrefsKey = 'screen_share_options';

  static Future<ScreenShareOptions> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kPrefsKey);
    if (raw == null) return defaults;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return ScreenShareOptions.fromJson(map);
    } catch (_) {
      return defaults;
    }
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kPrefsKey, jsonEncode(toJson()));
  }
}
