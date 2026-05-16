/// Tunnel servisi — playit.gg.
///
/// playit.gg: Ücretsiz, WebSocket desteği, kurulum gerektirmiyor.
/// playit.exe indirilir, çalıştırılır, URL alınır.
/// URL formatı: https://xxx.playit.gg veya doğrudan IP:port

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
  final List<String> _recentLogs = [];

  String? get publicUrl => _publicUrl;
  bool get running => _process != null && _publicUrl != null;
  bool get starting => _starting;
  String? get statusMessage => _statusMessage;
  List<String> get recentLogs => List.unmodifiable(_recentLogs);

  Future<String> start({int localPort = 3000}) async {
    if (_starting) {
      throw StateError('Tunnel zaten başlatılıyor');
    }
    if (running && _publicUrl != null) {
      return _publicUrl!;
    }

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
      _process = await Process.start(
        exePath,
        ['--tcp', 'localhost:$localPort'],
        mode: ProcessStartMode.normal,
      );
    } catch (e) {
      _starting = false;
      _statusMessage = 'playit.exe başlatılamadı: $e';
      notifyListeners();
      rethrow;
    }

    final urlRegex = RegExp(
        r'https://[a-zA-Z0-9][a-zA-Z0-9\-]*\.playit\.gg',
        caseSensitive: false);
    final portRegex =
        RegExp(r'(?:port|tunnel).*?(\d{2,5})', caseSensitive: false);

    void handleLine(String line) {
      _recentLogs.add(line);
	      while (_recentLogs.length > 50) { _recentLogs.removeAt(0); }
      debugPrint('[PLAYIT] $line');

      final m = urlRegex.firstMatch(line);
      if (m != null && !completer.isCompleted) {
        _publicUrl = m.group(0)!;
        _statusMessage = 'Tunnel aktif (playit.gg)';
        _starting = false;
        notifyListeners();
        completer.complete(_publicUrl!);
        return;
      }

      final pm = portRegex.firstMatch(line);
      if (pm != null && !completer.isCompleted) {
        final port = pm.group(1);
        if (port != null && port != localPort.toString()) {
          _resolvePublicIp().then((ip) {
            if (!completer.isCompleted) {
              _publicUrl = 'http://$ip:$port';
              _statusMessage = 'Tunnel aktif (playit.gg)';
              _starting = false;
              notifyListeners();
              completer.complete(_publicUrl!);
            }
          });
        }
      }
    }

    _process!.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen(handleLine);
    _process!.stderr
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen(handleLine);

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

  Future<void> stop() async {
    final p = _process;
    _process = null;
    _publicUrl = null;
    _statusMessage = 'Tunnel kapatıldı';
    notifyListeners();
    if (p != null) {
      try { p.kill(ProcessSignal.sigterm); } catch (_) {}
      try {
        await p.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        try { p.kill(ProcessSignal.sigkill); } catch (_) {}
      }
    }
  }

  String _resolvePlayitPath() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return '$exeDir\\playit.exe';
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
