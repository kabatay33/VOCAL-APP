/// Backend (Node.js) sunucusunu app yaşam döngüsüyle birlikte yöneten servis.
///
/// - App açılışında: `node src/server.js`'i subprocess olarak başlatır
/// - App kapanışında (TrayService Çıkış veya pencere kapatma): kill eder
/// - Port 3000 zaten kullanılıyorsa sessizce atlar
/// - Backend klasörü veya node.exe bulunamazsa sessizce atlar (friend'ın cihazında
///   olabilir — friend backend'e ihtiyaç duymaz, Cloudflare URL üzerinden bağlanır)
///
/// Backend klasörünü ararken aşağıdaki yolları sırayla dener:
/// 1) Bundled: `runner_dir/backend/`  (üretim build'i için ileride bundlable)
/// 2) Development: `runner_dir/../../../../../backend/`  (flutter build'in
///    standart layout'u — runner Release exe'nin üst klasörlerinde proje root)
library;

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

class BackendProcessService {
  static final BackendProcessService instance = BackendProcessService._();
  BackendProcessService._();

  Process? _process;
  bool get running => _process != null;
  String? _resolvedBackendDir;
  String? _resolvedNodePath;

  /// Backend'i ayağa kaldırmaya çalışır. Hata olursa sadece debugPrint —
  /// app yine açılır.
  Future<void> start() async {
    if (_process != null) return;
    if (!Platform.isWindows) return;
    // Port 3000 zaten dinleniyor mu kontrol et (başka instance veya manuel
    // backend zaten çalışıyor olabilir)
    if (await _isPort3000InUse()) {
      debugPrint('[BACKEND] Port 3000 zaten kullanımda — start atlandı');
      return;
    }
    final backendDir = _findBackendDir();
    if (backendDir == null) {
      debugPrint('[BACKEND] backend/ klasörü bulunamadı — start atlandı');
      return;
    }
    final nodePath = await _findNode();
    if (nodePath == null) {
      debugPrint('[BACKEND] node bulunamadı (PATH\'de yok) — start atlandı');
      return;
    }
    _resolvedBackendDir = backendDir;
    _resolvedNodePath = nodePath;
    try {
      _process = await Process.start(
        nodePath,
        ['src/server.js'],
        workingDirectory: backendDir,
        // 'normal' mode: child stdio'su parent'a bağlı — app öldürüldüğünde
        // (örn. task manager) child da kapanır. Detached olsaydı yetim kalırdı.
        mode: ProcessStartMode.normal,
      );
      debugPrint(
          '[BACKEND] başlatıldı: $nodePath src/server.js (cwd=$backendDir, pid=${_process!.pid})');
      // stdout/stderr'i debug log'a aktarır (test için)
      _process!.stdout
          .transform(const SystemEncoding().decoder)
          .listen((line) {
        final s = line.trim();
        if (s.isNotEmpty) debugPrint('[BACKEND] $s');
      });
      _process!.stderr
          .transform(const SystemEncoding().decoder)
          .listen((line) {
        final s = line.trim();
        if (s.isNotEmpty) debugPrint('[BACKEND-ERR] $s');
      });
      _process!.exitCode.then((code) {
        debugPrint('[BACKEND] process bitti (kod=$code)');
        _process = null;
      });
    } catch (e) {
      debugPrint('[BACKEND] başlatılamadı: $e');
      _process = null;
    }
  }

  /// Backend'in port 3000'de hazır olmasını bekle.
  /// [timeout] kadar saniye bekler, hazır olursa true döner.
  Future<bool> waitForReady({int timeoutSeconds = 10}) async {
    final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds));
    while (DateTime.now().isBefore(deadline)) {
      if (await _isPort3000InUse()) return true;
      await Future.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  /// Backend'i kapat. Pencere kapatma / tray çıkış sırasında çağrılır.
  Future<void> stop() async {
    final p = _process;
    _process = null;
    if (p == null) return;
    try {
      // Önce graceful (SIGTERM Windows'ta CTRL_BREAK_EVENT emulate eder ama
      // Process.kill default olarak çalışıyor)
      p.kill(ProcessSignal.sigterm);
      // 2 sn bekle, hala kapanmadıysa SIGKILL
      try {
        await p.exitCode.timeout(const Duration(seconds: 2));
        debugPrint('[BACKEND] graceful kapatıldı');
        return;
      } catch (_) {
        // Timeout — zorla öldür
      }
      p.kill(ProcessSignal.sigkill);
      debugPrint('[BACKEND] zorla öldürüldü');
    } catch (e) {
      debugPrint('[BACKEND] kapatma hatası: $e');
    }
  }

  // ====== yol arama ======

  String? _findBackendDir() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      // 1) Bundled: runner_dir/backend/
      '$exeDir\\backend',
      // 2) Dev build (Release): proje root = runner_dir 6 üst klasör
      //    Release ↑ runner ↑ x64 ↑ windows ↑ build ↑ flutter_app ↑ discord-clone
      '$exeDir\\..\\..\\..\\..\\..\\..\\backend',
      // 3) Dev build (Debug): aynı yapı
      '$exeDir\\..\\..\\..\\..\\..\\backend',
    ];
    for (final path in candidates) {
      final dir = Directory(path);
      if (dir.existsSync() &&
          File('${dir.path}\\src\\server.js').existsSync()) {
        debugPrint('[BACKEND] backend bulundu: ${dir.absolute.path}');
        return dir.absolute.path;
      } else {
        debugPrint('[BACKEND] denenen path geçersiz: $path');
      }
    }
    return null;
  }

  Future<String?> _findNode() async {
    // 1) Bundled node.exe runner yanında
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final bundled = File('$exeDir\\node.exe');
    if (bundled.existsSync()) return bundled.path;
    // 2) PATH'den node ara
    try {
      final result = await Process.run('where', ['node'],
          runInShell: false, stdoutEncoding: const SystemEncoding());
      if (result.exitCode == 0) {
        final lines = (result.stdout as String).split('\n');
        for (final l in lines) {
          final s = l.trim();
          if (s.toLowerCase().endsWith('node.exe') && File(s).existsSync()) {
            return s;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<bool> _isPort3000InUse() async {
    try {
      final server = await ServerSocket.bind('127.0.0.1', 3000);
      await server.close();
      return false;
    } catch (_) {
      return true;
    }
  }

  String? get backendDir => _resolvedBackendDir;
  String? get nodePath => _resolvedNodePath;
}
