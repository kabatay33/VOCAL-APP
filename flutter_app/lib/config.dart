import 'dart:io';
import 'package:flutter/foundation.dart';

/// Backend sunucusunun adresi.
///
/// İlk açılışta varsayılan değer kullanılır. Kullanıcı login ekranındaki
/// "Sunucu" alanından değiştirebilir; değiştirilen değer SharedPreferences'a
/// kaydedilip her açılışta yüklenir (bkz. main.dart).
class Config {
  /// Default host yok — kullanıcı her zaman sunucu seçmeli (Cloudflare URL).
  static const String defaultHost = '';

  /// GitHub Releases üzerinden auto-update — repo bilgileri.
  /// Yeni sürüm yayınlama: `gh release create v1.0.X ./dist.zip --notes "..."`
  static const String githubOwner = 'kabatay33';
  static const String githubRepo = 'LocalHub';

  /// GitHub Releases API endpoint'i (latest release).
  static String get githubLatestReleaseUrl =>
      'https://api.github.com/repos/$githubOwner/$githubRepo/releases/latest';

  static String _runtimeHost = defaultHost;

  static String get backendHost {
    // Android emulator'den lokal sunucuya 10.0.2.2 kullanılır.
    // Ama VPN/LAN bağlantısında IP doğrudan kullanılır.
    if (_runtimeHost == 'localhost' || _runtimeHost == '127.0.0.1') {
      if (!kIsWeb && Platform.isAndroid) return '10.0.2.2';
    }
    return _runtimeHost;
  }

  static void setHost(String host) {
    final cleaned = host.trim();
    if (cleaned.isNotEmpty) _runtimeHost = cleaned;
  }

  /// Host bir URL ise (https://... veya http://...) doğrudan kullan, IP/host
  /// ise port 3000 ekle. Cloudflare Tunnel URL'leri https şemasında, port'suz.
  static String get httpBase {
    final h = backendHost;
    if (h.startsWith('http://') || h.startsWith('https://')) {
      // URL kullanıcının verdiği gibi (trailing / olmadan)
      return h.endsWith('/') ? h.substring(0, h.length - 1) : h;
    }
    return 'http://$h:3000';
  }

  /// WebSocket URL — https://X → wss://X/ws, http://X → ws://X/ws,
  /// X (IP) → ws://X:3000/ws
  static String wsUrl(String token) {
    final h = backendHost;
    if (h.startsWith('https://')) {
      final rest = h.substring('https://'.length);
      final clean = rest.endsWith('/') ? rest.substring(0, rest.length - 1) : rest;
      return 'wss://$clean/ws?token=$token';
    }
    if (h.startsWith('http://')) {
      final rest = h.substring('http://'.length);
      final clean = rest.endsWith('/') ? rest.substring(0, rest.length - 1) : rest;
      return 'ws://$clean/ws?token=$token';
    }
    return 'ws://$h:3000/ws?token=$token';
  }
}
