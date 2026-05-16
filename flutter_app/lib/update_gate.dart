/// Uygulama açılış kapısı — Backend hazır bekleyen splash.
///
/// Akış:
///   1) BackendProcessService zaten main()'de başlatılmış olabilir.
///   2) Port 3000 dinleniyor mu kontrol et (backend hazır mı?)
///   3) Hazır değilse bekle (max 15 sn), arada durum göster.
///   4) Hazır veya timeout → Bootstrap'a geç.
///
/// Not: Güncelleme kontrolü artık updater.exe tarafından yapılıyor.
/// Updater güncelleme bittikten sonra discord_clone.exe'yi başlatıyor.
/// Bu splash sadece backend'in hazır olmasını bekliyor.

library;

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'main.dart' show Bootstrap;
import 'storage.dart';

class UpdateGate extends StatefulWidget {
  const UpdateGate({super.key});

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> {
  String _status = 'Hazırlanıyor...';
  bool _proceeded = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      // Kayıtlı sunucu var mı?
      final host = await Storage.getServerHost();
      if (host == null || host.trim().isEmpty) {
        _setStatus('Sunucu ayarlı değil — bekleniyor...');
        // Sunucu ayarlanmamışsa backend'e gerek yok, direkt git
        await Future.delayed(const Duration(milliseconds: 800));
        _proceedToApp();
        return;
      }

      // Backend hazır mı kontrol et
      _setStatus('Sunucu başlatılıyor...');

      // Önce port 3000'i kontrol et (zaten çalışıyor olabilir)
      if (await _isPort3000Ready()) {
        _setStatus('Sunucu hazır!');
        await Future.delayed(const Duration(milliseconds: 400));
        _proceedToApp();
        return;
      }

      // Backend'in hazır olmasını bekle (max 15 sn)
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;

        if (await _isPort3000Ready()) {
          _setStatus('Sunucu hazır!');
          await Future.delayed(const Duration(milliseconds: 400));
          _proceedToApp();
          return;
        }

        final elapsed = 15 - deadline.difference(DateTime.now()).inSeconds;
        _setStatus('Sunucu başlatılıyor... (${elapsed}s)');
      }

      // Timeout — yine de devam et (backend manuel açılabilir)
      _setStatus('Sunucu bekleniyor... (devam ediliyor)');
      await Future.delayed(const Duration(milliseconds: 600));
      _proceedToApp();
    } catch (e) {
      _setStatus('Hata: $e — devam ediliyor');
      await Future.delayed(const Duration(milliseconds: 800));
      _proceedToApp();
    }
  }

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  Future<bool> _isPort3000Ready() async {
    try {
      final socket = await Socket.connect('127.0.0.1', 3000,
          timeout: const Duration(seconds: 1));
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
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
              const SizedBox(
                width: 280,
                child: LinearProgressIndicator(
                  minHeight: 4,
                  backgroundColor: Colors.white12,
                  color: Color(0xFF5865F2),
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
              const SizedBox(height: 16),
              TextButton(
                onPressed: _proceedToApp,
                child: const Text(
                  'Atla ve devam et',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
