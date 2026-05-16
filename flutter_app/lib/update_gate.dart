/// Uygulama açılış kapısı — Updater splash.
///
/// Akış:
///   1) Backend ulaşılabilir mi diye 3 sn'lik retry-pinger çalıştırır.
///   2) Manifest'i çeker.
///   3) Yeni sürüm varsa otomatik indir → PowerShell update script çalıştırır
///      → app exit(0) yapar.
///   4) Yoksa, hata olursa veya backend ulaşılamıyorsa → normal Bootstrap'e geç.
///
/// Splash UI: Discord renkleri, logo, durum text + opsiyonel progress bar.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'main.dart' show Bootstrap;
import 'storage.dart';
import 'updater_service.dart';

class UpdateGate extends StatefulWidget {
  const UpdateGate({super.key});

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> {
  String _status = 'Hazırlanıyor...';
  double? _progress; // null = indeterminate, 0..1 = determinate
  bool _showCancel = false;
  bool _proceeded = false; // _proceedToApp birden fazla çağrılmasın

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      // 1) Kayıtlı sunucu var mı? Yoksa update kontrolü atla
      final host = await Storage.getServerHost();
      if (host == null || host.trim().isEmpty) {
        _setStatus('Sunucu ayarlı değil — atlanıyor');
        await Future.delayed(const Duration(milliseconds: 400));
        _proceedToApp();
        return;
      }

      // 1.5) Son güncelleme zamanını kontrol et — 1 saat içinde yapıldıysa atla
      final lastUpdate = await Storage.getLastUpdateCheck();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (lastUpdate != null && (now - lastUpdate) < 3600000) {
        _setStatus('Güncelleme yakın zamanda yapıldı — atlanıyor');
        await Future.delayed(const Duration(milliseconds: 400));
        _proceedToApp();
        return;
      }

      // 2) GitHub'dan güncelleme kontrolü
      _setStatus('Güncelleme kontrolü...');
      _showCancelAfter(const Duration(seconds: 5));
      final result = await UpdaterService.instance
          .checkForUpdate()
          .timeout(const Duration(seconds: 10));

      // Kontrol zamanını kaydet
      await Storage.setLastUpdateCheck(now);

      if (!result.hasUpdate) {
        _setStatus('Güncel: ${result.currentVersion}');
        await Future.delayed(const Duration(milliseconds: 300));
        _proceedToApp();
        return;
      }

      // 3) Yeni sürüm var → otomatik indir + uygula
      _setStatus(
          'Yeni sürüm bulundu: ${result.latestVersion}\nİndiriliyor...');
      setState(() => _progress = 0);
      await UpdaterService.instance.downloadAndApply(
        result.release,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      // downloadAndApply içinde exit(0) — buraya gelmemeli
    } catch (e) {
      _setStatus('Güncelleme atlandı: $e');
      await Future.delayed(const Duration(milliseconds: 800));
      _proceedToApp();
    }
  }

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  void _showCancelAfter(Duration d) {
    Timer(d, () {
      if (mounted) setState(() => _showCancel = true);
    });
  }

  void _proceedToApp() {
    if (_proceeded || !mounted) return;
    _proceeded = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const Bootstrap()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1F22),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: const Color(0xFF5865F2),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF5865F2).withValues(alpha: 0.5),
                      blurRadius: 24,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: const Icon(Icons.chat_bubble,
                    color: Colors.white, size: 48),
              ),
              const SizedBox(height: 28),
              const Text(
                'Discord Clone',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 24),
              // İlerleme göstergesi
              SizedBox(
                width: 280,
                child: LinearProgressIndicator(
                  value: _progress,
                  minHeight: 4,
                  backgroundColor: Colors.white12,
                  color: const Color(0xFF5865F2),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: 280,
                child: Text(
                  _status,
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
              if (_progress != null && _progress! > 0) ...[
                const SizedBox(height: 6),
                Text(
                  '${(_progress! * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontFamily: 'monospace'),
                ),
              ],
              if (_showCancel && _progress == null) ...[
                const SizedBox(height: 16),
                TextButton(
                  onPressed: _proceedToApp,
                  child: const Text(
                    'Atla ve devam et',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
