/// Cloudflare Tunnel (TryCloudflare) entegrasyonu.
///
/// Host PC'sinde `cloudflared.exe` subprocess olarak çalıştırılır;
/// `--url http://localhost:3000` ile local backend'i Cloudflare CDN
/// üzerinden public bir HTTPS URL'e proxy'ler. Hesap, kayıt veya yapılandırma
/// gerekmez — TryCloudflare anonim tunnel verir.
///
/// Sonuç URL örnek: https://random-words-here.trycloudflare.com
/// Bu URL hem HTTP API hem WebSocket için kullanılabilir; Cloudflare TLS
/// terminate eder ve backend'imize ws://localhost:3000 olarak forward eder.
///
/// Arkadaşlar bu URL'i Hamachi panelinden "Ağa Katıl" formuna yapıştırır.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class TunnelService extends ChangeNotifier {
  static final TunnelService instance = TunnelService._();
  TunnelService._();

  Process? _process;
  String? _publicUrl;
  String? _statusMessage;
  bool _starting = false;
  // En son terminal log satırı (debug)
  final List<String> _recentLogs = [];

  String? get publicUrl => _publicUrl;
  bool get running => _process != null && _publicUrl != null;
  bool get starting => _starting;
  String? get statusMessage => _statusMessage;
  List<String> get recentLogs => List.unmodifiable(_recentLogs);

  /// Cloudflared'i başlat. `localPort` backend'in dinlediği port (default 3000).
  /// Dönüş: public URL (https://...). Hata olursa exception fırlatır.
  Future<String> start({int localPort = 3000}) async {
    if (_starting) {
      throw StateError('Tunnel zaten başlatılıyor');
    }
    if (running && _publicUrl != null) {
      return _publicUrl!;
    }
    _starting = true;
    _statusMessage = 'Cloudflared başlatılıyor...';
    notifyListeners();

    // cloudflared.exe runner exe yanında (CMakeLists kopyalıyor)
    final exePath = _resolveCloudflaredPath();
    if (!await File(exePath).exists()) {
      _starting = false;
      _statusMessage = 'cloudflared.exe bulunamadı';
      notifyListeners();
      throw FileSystemException(
          'cloudflared.exe bulunamadı: $exePath\n'
          'Build çıktısının içinde olmalı.');
    }

    final completer = Completer<String>();
    Timer? timeoutTimer;

    try {
      _process = await Process.start(
        exePath,
        [
          'tunnel',
          '--no-autoupdate',
          '--url',
          'http://localhost:$localPort',
          '--logfile',
          // cloudflared'ın kendi logu için temp dizini
          _logFilePath(),
        ],
        mode: ProcessStartMode.normal,
      );
    } catch (e) {
      _starting = false;
      _statusMessage = 'cloudflared başlatılamadı: $e';
      notifyListeners();
      rethrow;
    }

    final urlRegex = RegExp(
        r'https://[a-zA-Z0-9\-]+\.trycloudflare\.com',
        caseSensitive: false);

    void handleLine(String line) {
      _recentLogs.add(line);
      while (_recentLogs.length > 50) {
        _recentLogs.removeAt(0);
      }
      final m = urlRegex.firstMatch(line);
      if (m != null && !completer.isCompleted) {
        final url = m.group(0)!;
        _publicUrl = url;
        _statusMessage = 'Tunnel aktif';
        _starting = false;
        notifyListeners();
        completer.complete(url);
      }
    }

    _process!.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen(handleLine, onError: (e) {
      debugPrint('[TUNNEL] stdout error: $e');
    });
    _process!.stderr
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen(handleLine, onError: (e) {
      debugPrint('[TUNNEL] stderr error: $e');
    });

    _process!.exitCode.then((code) {
      debugPrint('[TUNNEL] cloudflared çıktı: code=$code');
      _process = null;
      _publicUrl = null;
      _statusMessage = code == 0 ? 'Tunnel kapandı' : 'Tunnel hatası (kod $code)';
      _starting = false;
      notifyListeners();
      if (!completer.isCompleted) {
        completer.completeError(StateError(
            'cloudflared erken çıktı (kod $code). Loglar:\n${_recentLogs.join("\n")}'));
      }
    });

    // 30 saniye sonra URL gelmemişse timeout
    timeoutTimer = Timer(const Duration(seconds: 30), () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException(
            'Cloudflare tunnel 30 sn içinde URL döndürmedi.\nLoglar:\n${_recentLogs.join("\n")}'));
      }
    });

    try {
      final url = await completer.future;
      timeoutTimer.cancel();
      return url;
    } catch (e) {
      timeoutTimer.cancel();
      await stop();
      rethrow;
    }
  }

  Future<void> stop() async {
    final p = _process;
    _process = null;
    _publicUrl = null;
    _statusMessage = 'Tunnel kapatıldı';
    notifyListeners();
    if (p != null) {
      try {
        p.kill(ProcessSignal.sigterm);
      } catch (_) {}
      try {
        await p.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        try {
          p.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
    }
  }

  String _resolveCloudflaredPath() {
    // Platform.resolvedExecutable: …/discord_clone.exe → cloudflared.exe aynı klasörde
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return '$exeDir\\cloudflared.exe';
  }

  String _logFilePath() {
    final tmp = Directory.systemTemp;
    return '${tmp.path}\\cloudflared_discord_clone.log';
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
