import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'backend_process_service.dart';
import 'tunnel_service.dart';

/// System tray entegrasyonu.
///
/// - Sağ tıklama menüsü: Göster / Çıkış
/// - Sol tıklama / double-click: pencereyi göster + öne getir
/// - Pencere kapatma butonu tray'e küçültür (gerçek çıkış yalnız menüden)
class TrayService extends TrayListener with WindowListener {
  static final TrayService _instance = TrayService._();
  factory TrayService() => _instance;
  TrayService._();

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    if (kIsWeb || !(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return;
    }
    try {
      // Asset'i geçici klasöre kopyala — tray_manager file path bekler
      final iconPath = await _materializeIcon();
      await trayManager.setIcon(iconPath);
      await trayManager.setToolTip('LocalHub');
      await _refreshMenu();
      trayManager.addListener(this);
      windowManager.addListener(this);
      // Pencere kapatma X butonunu yakala — uygulamayı gerçekten kapatma
      await windowManager.setPreventClose(true);
    } catch (e) {
      debugPrint('[TRAY] init hatası: $e');
    }
  }

  Future<String> _materializeIcon() async {
    final bytes = await rootBundle.load('assets/app_icon.ico');
    final tempDir = Directory.systemTemp;
    final sep = Platform.pathSeparator;
    final file = File('${tempDir.path}${sep}localhub_tray.ico');
    await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    return file.path;
  }

  Future<void> _refreshMenu() async {
    final menu = Menu(items: [
      MenuItem(key: 'show', label: 'Göster'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Çıkış'),
    ]);
    await trayManager.setContextMenu(menu);
  }

  Future<void> dispose() async {
    if (!_initialized) return;
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    try {
      await trayManager.destroy();
    } catch (_) {}
  }

  Future<void> _showWindow() async {
    if (!await windowManager.isVisible()) {
      await windowManager.show();
    }
    await windowManager.focus();
  }

  Future<void> _hideToTray() async {
    await windowManager.hide();
  }

  // ===== TrayListener =====
  @override
  void onTrayIconMouseDown() {
    // Sol tık → pencereyi göster
    _showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _showWindow();
        break;
      case 'quit':
        _reallyExit();
        break;
    }
  }

  // ===== WindowListener =====
  @override
  void onWindowClose() async {
    // X tuşu → tray'e küçült (gerçek çıkış sadece menüden)
    final prevent = await windowManager.isPreventClose();
    if (prevent) {
      await _hideToTray();
    }
  }

  Future<void> _reallyExit() async {
    // Önce preventClose'u kapat ki destroy çalışsın
    await windowManager.setPreventClose(false);
    // Yan servisleri temiz kapat — backend node process ve cloudflared
    try {
      // Tunnel service artik playit degil, Radmin VPN kontrolu yapilmaz
    } catch (_) {}
    try {
      await BackendProcessService.instance.stop();
    } catch (_) {}
    await dispose();
    await windowManager.destroy();
  }
}
