import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Windows native input injection için platform channel bridge.
///
/// Gelen uzaktan input event'lerini Windows SendInput API'ye iletir.
/// Sadece Windows masaüstünde çalışır; diğer platformlarda no-op.
class InputManager {
  static const _channel = MethodChannel('com.discord_clone/input');
  static bool _initialized = false;

  /// Platform channel'ı başlat.
  static Future<void> init() async {
    if (_initialized) return;
    if (!Platform.isWindows) {
      debugPrint('[INPUT] Windows dışı platform, input injection devre dışı');
      return;
    }
    _channel.setMethodCallHandler(_handleCall);
    _initialized = true;
  }

  /// VoiceManager'dan gelen input event'i işle.
  static Future<void> handleInputEvent(Map<String, dynamic> event) async {
    if (!_initialized || !Platform.isWindows) return;
    try {
      await _channel.invokeMethod('handleInput', jsonEncode(event));
    } catch (e) {
      debugPrint('[INPUT] Event işlenemedi: $e');
    }
  }

  static Future<dynamic> _handleCall(MethodCall call) async {
    // Native'den gelecek çağrılar olursa burada işlenir
    debugPrint('[INPUT] Native çağrı: ${call.method}');
  }
}
