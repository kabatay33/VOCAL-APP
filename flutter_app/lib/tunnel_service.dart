/// Tunnel servisi — playit.gg (varsayılan) ve Cloudflare Tunnel (fallback).
///
/// playit.gg: Ücretsiz, WebSocket desteği, kurulum gerektirmiyor.
/// playit.exe indirilir, çalıştırılır, URL alınır.
/// URL formatı: https://xxx.playit.gg veya doğrudan IP:port
///
/// Cloudflare Tunnel: TryCloudflare anonim tunnel.
/// URL formatı: https://random.trycloudflare.com

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

enum TunnelProvider { playit, cloudflare }

class TunnelService extends ChangeNotifier {
  static final TunnelService instance = TunnelService._();
  TunnelService._();

  Process? _process;
  String? _publicUrl;
  String? _statusMessage;
  bool _starting = false;
  TunnelProvider _provider = TunnelProvider.playit;
  final List<String> _recentLogs = [];

  String? get publicUrl => _publicUrl;
  bool get running => _process != null && _publicUrl != null;
  bool get starting => _starting;
  String? get statusMessage => _statusMessage;
  List<String> get recentLogs => List.unmodifiable(_recentLogs);
  TunnelProvider get provider => _provider;

  /// Tunnel başlat. Varsayılan: playit.gg
  Future<String> start({
    int localPort = 3000,
    TunnelProvider provider = TunnelProvider.playit,
  }) async {
    if (_starting) {
      throw StateError('Tunnel zaten başlatılıyor');
    }
    if (running && _publicUrl != null) {
      return _publicUrl!;
    }
    _provider = provider;

    if (provider == TunnelProvider.playit) {
      return _startPlayit(localPort: localPort);
    } else {
      return _startCloudflare(localPort: localPort);
    }
  }

  // ============================================================
  // playit.gg
  // ============================================================

  Future<String> _startPlayit({required int localPort}) async {
    _starting = true;
    _statusMessage = 'playit.gg başlatılıyor...';
    notifyListeners();

    final exePath = _resolvePlayitPath();
    if (!await File(exePath).exists()) {
      _starting = false;
      _statusMessage = 'playit.exe bulunamadı';
      notifyListeners();
      throw FileSystemException(
          'playit.exe bulunamadı: $exePath\n'
          'Önce scripts/download-playit.ps1 çalıştırın.');
    }

    final completer = Completer<String>();
    Timer? timeoutTimer;

    try {
      // playit.gg: secret key olmadan çalışır (anonim tunnel)
      // --tcp localhost:3000 forward eder
      _process = await Process.start(
        exePath,
        [
          '--tcp',
          'localhost:$localPort',
        ],
        mode: ProcessStartMode.normal,
      );
    } catch (e) {
      _starting = false;
      _statusMessage = 'playit.exe başlatılamadı: $e';
      notifyListeners();
      rethrow;
    }

    // playit.gg URL formatları:
    // "Tunnel started: https://xxx.playit.gg" veya
    // "Listening on: 0.0.0.0:xxxxx" (doğrudan port)
    final urlRegex = RegExp(
        r'https://[a-zA-Z0-9][a-zA-Z0-9\-]*\.playit\.gg',
        caseSensitive: false);
    // Doğrudan port forwarding: "Listening on port XXXXX" veya "tunnel.*:XXXXX"
    final portRegex = RegExp(r'(?:port|tunnel).*?(\d{2,5})', caseSensitive: false);

    void handleLine(String line) {
      _recentLogs.add(line);
      while (_recentLogs.length > 50) {
        _recentLogs.removeAt(0);
      }
      debugPrint('[PLAYIT] $line');

      // Önce URL formatını ara
      final m = urlRegex.firstMatch(line);
      if (m != null && !completer.isCompleted) {
        final url = m.group(0)!;
        _publicUrl = url;
        _statusMessage = 'Tunnel aktif (playit.gg)';
        _starting = false;
        notifyListeners();
        completer.complete(url);
        return;
      }

      // Port forwarding formatı — public IP:port
      final pm = portRegex.firstMatch(line);
      if (pm != null && !completer.isCompleted) {
        final port = pm.group(1);
        if (port != null && port != localPort.toString()) {
          // playit.gg doğrudan port veriyor — IP'yi bul
          _resolvePublicIp().then((ip) {
            if (!completer.isCompleted) {
              final url = 'http://$ip:$port';
              _publicUrl = url;
              _statusMessage = 'Tunnel aktif (playit.gg)';
              _starting = false;
              notifyListeners();
              completer.complete(url);
            }
          });
        }
      }
    }

    _process!.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen(handleLine, onError: (e) {
      debugPrint('[PLAYIT] stdout error: $e');
    });
    _process!.stderr
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen(handleLine, onError: (e) {
      debugPrint('[PLAYIT] stderr error: $e');
    });

    _process!.exitCode.then((code) {
      debugPrint('[PLAYIT] çıktı: code=$code');
      _process = null;
      _publicUrl = null;
      _statusMessage = code == 0 ? 'Tunnel kapandı' : 'Tunnel hatası (kod $code)';
      _starting = false;
      notifyListeners();
      if (!completer.isCompleted) {
        completer.completeError(StateError(
            'playit erken çıktı (kod $code). Loglar:\n${_recentLogs.join("\n")}'));
      }
    });

    // 45 saniye timeout (playit.gg biraz uzun sürebilir)
    timeoutTimer = Timer(const Duration(seconds: 45), () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException(
            'playit.gg 45 sn içinde URL döndürmedi.\nLoglar:\n${_recentLogs.join("\n")}'));
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

  Future<String> _resolvePublicIp() async {
    try {
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse('https://api.ipify.org'));
      final res = await req.close();
      final body = await res.transform(const SystemEncoding().decoder).join();
      client.close();
      return body.trim();
    } catch (_) {
      return '0.0.0.0';
    }
  }

  // ============================================================
  // Cloudflare Tunnel (fallback)
  // ============================================================

  Future<String> _startCloudflare({required int localPort}) async {
    _starting = true;
    _statusMessage = 'Cloudflare Tunnel başlatılıyor...';
    notifyListeners();

    final exePath = _resolveCloudflaredPath();
    if (!await File(exePath).exists()) {
      _starting = false;
      _statusMessage = 'cloudflared.exe bulunamadı';
      notifyListeners();
      throw FileSystemException(
          'cloudflared.exe bulunamadı: $exePath');
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
        r'https://[a-zA-Z0-9][a-zA-Z0-9\-]*\.trycloudflare\.com',
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
        _statusMessage = 'Tunnel aktif (Cloudflare)';
        _starting = false;
        notifyListeners();
        completer.complete(url);
      }
    }

    _process!.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen(handleLine, onError: (e) {
      debugPrint('[CF] stdout error: $e');
    });
    _process!.stderr
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen(handleLine, onError: (e) {
      debugPrint('[CF] stderr error: $e');
    });

    _process!.exitCode.then((code) {
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

  String _resolvePlayitPath() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return '$exeDir\\playit.exe';
  }

  String _resolveCloudflaredPath() {
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
