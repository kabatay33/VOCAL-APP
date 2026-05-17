/// Tunnel servisi — Artık playit.gg YOK.
///
/// Sunucu bağlantısı doğrudan Radmin VPN IP adresi ile yapılır.
/// Kullanıcı Radmin VPN'den aldığı IP'yi "Yeni Sunucu Ekle" ile kaydeder.
/// Updater çalıştığında Radmin VPN'ın açık olup olmadığını kontrol eder.

library;

import 'dart:io';
import 'package:flutter/foundation.dart';

class TunnelService extends ChangeNotifier {
  static final TunnelService instance = TunnelService._();
  TunnelService._();

  /// Radmin VPN exe yolu
  static const String radminVpnPath = r'C:\Program Files (x86)\Radmin VPN\RvRvpnGui.exe';

  /// Radmin VPN'in calisip calismadigini kontrol et
  static bool isRadminVpnRunning() {
    try {
      final r = Process.runSync('tasklist', ['/FI', 'IMAGENAME eq RvRvpnGui.exe', '/NH'], runInShell: false);
      return (r.stdout as String).toLowerCase().contains('rvrvpngui.exe');
    } catch (_) {
      return false;
    }
  }

  /// Radmin VPN baslat (eger calismiyorsa)
  static Future<bool> startRadminVpn() async {
    try {
      final exe = File(radminVpnPath);
      if (!await exe.exists()) {
        debugPrint('[TUNNEL] Radmin VPN bulunamadi: $radminVpnPath');
        return false;
      }
      if (isRadminVpnRunning()) {
        debugPrint('[TUNNEL] Radmin VPN zaten calisiyor');
        return true;
      }
      debugPrint('[TUNNEL] Radmin VPN baslatiliyor...');
      Process.start(radminVpnPath, [], mode: ProcessStartMode.detached, runInShell: false);
      // Baslamasi icin bekle
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(seconds: 1));
        if (isRadminVpnRunning()) {
          debugPrint('[TUNNEL] Radmin VPN baslatildi');
          return true;
        }
      }
      debugPrint('[TUNNEL] Radmin VPN baslatilamadi (timeout)');
      return false;
    } catch (e) {
      debugPrint('[TUNNEL] Radmin VPN baslatma hatasi: $e');
      return false;
    }
  }

  @override
  void dispose() {
    super.dispose();
  }
}
