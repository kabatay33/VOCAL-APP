/// Tunnel servisi — playit.gg.
///
/// playit.gg: Ücretsiz, WebSocket desteği.
/// playit.exe secret key ile çalışır.
/// Secret key: https://playit.gg/account → "Create Secret Key"
///
/// Not: playit.exe --tcp DESTEKLENMIYOR (yeni versiyon).
/// Yeni versiyon --secret ile çalışır ve otomatik tunnel oluşturur.

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
  String? _secretKey;
  final List<String> _recentLogs = [];

  String? get publicUrl => _publicUrl;
  bool get running => _process != null && _publicUrl != null;
  bool get starting => _starting;
  String? get statusMessage => _statusMessage;
  List<String> get recentLogs => List.unmodifiable(_recentLogs);

  /// Secret key ayarla (https://playit.gg/account'dan alınır).
  void setSecretKey(String key) {
    _secretKey = key.trim();
  }

  Future<String> start({int localPort = 3000}) async {
    if (_starting) {
      throw StateError('Tunnel zaten başlatılıyor');
    }
    if (running && _publicUrl != null) {
      return _publicUrl!;
    }

    if (_secretKey == null || _secretKey!.isEmpty) {
      _statusMessage = 'playit.gg secret key gerekli';
      notifyListeners();
      throw StateError(
        'playit.gg secret key ayarlanmamış.\n'
        'https://playit.gg/account → "Create Secret Key"\n'
        'Sonra: TunnelService.instance.setSecretKey("key-xxx")');
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
        ['--secret', _secretKey!],
        mode: ProcessStartMode.normal,
      );
    } catch (e) {
      _starting = false;
      _statusMessage = 'playit.exe başlatılamadı: $e';
      notifyListeners();
      rethrow;
    }

    // playit.gg URL formatı: "tunnel.*: https://xxx.playit.gg" veya benzeri
    final urlRegex = RegExp(
        r'https://[a-zA-Z0-9][a-zA-Z0-9\-]*\.playit\.gg',
        caseSensitive: false);

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

    timeoutTimer = Timer(const Duration(seconds: 60), () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException(
            'playit.gg 60 sn içinde URL döndürmedi.\nLoglar:\n${_recentLogs.join("\n")}'));
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
