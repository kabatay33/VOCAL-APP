/// Uygulama açılış kapısı — güncelleme kontrolü + backend hazırlık splash'i.
///
/// Akış:
///   1) GitHub'tan en son sürümü çek
///   2) Yerel version.txt ile karşılaştır
///   3) Yeni sürüm varsa: indir (progress bar), pakage'i staging'e çıkar,
///      apply script'i invisible spawn et, kendini kapat
///   4) Güncelleme yoksa: backend'in port 3000'i açmasını bekle
///   5) Hazır olunca Bootstrap'a geç
///
/// Tüm aşamalarda ekranın tam ortasında LocalHub logo + progress bar +
/// durum metni gösterilir.

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'config.dart';
import 'main.dart' show Bootstrap, invisibleSpawn;
import 'storage.dart';

class UpdateGate extends StatefulWidget {
  const UpdateGate({super.key});

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate>
    with TickerProviderStateMixin {
  String _status = 'Hazırlanıyor...';
  double? _progress; // null = belirsiz, 0..1 = belirli
  bool _proceeded = false;
  String? _errorDetail;
  late final AnimationController _spinCtrl;

  @override
  void initState() {
    super.initState();
    _spinCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    _run();
  }

  @override
  void dispose() {
    _spinCtrl.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    try {
      // 1) Güncelleme kontrolü (sadece Windows release modunda)
      if (!kIsWeb && Platform.isWindows && kReleaseMode) {
        final updated = await _checkAndApplyUpdate();
        if (updated) {
          // İşlem zaten exit yaptı, buraya gelmemeli
          return;
        }
      }

      // 2) Backend hazırlığı
      await _waitForBackend();
      _proceedToApp();
    } catch (e, st) {
      debugPrint('[UpdateGate] Beklenmeyen hata: $e\n$st');
      _setStatus('Hata: $e — devam ediliyor');
      await Future.delayed(const Duration(milliseconds: 800));
      _proceedToApp();
    }
  }

  // ============================================================
  // Güncelleme kontrolü ve uygulama
  // ============================================================

  /// Dönüş: true = güncelleme uygulandı (process exit'lemeli),
  ///         false = güncelleme yok / başarısız (normal akışa devam et)
  Future<bool> _checkAndApplyUpdate() async {
    try {
      _setStatus('Güncellemeler kontrol ediliyor...');
      _setProgress(null);

      final currentVersion = _readCurrentVersion();
      debugPrint('[UpdateGate] Mevcut sürüm: ${currentVersion ?? "bilinmiyor"}');

      final release = await _fetchLatestRelease();
      if (release == null) {
        _setStatus('Sürüm bilgisi alınamadı — devam ediliyor');
        await Future.delayed(const Duration(milliseconds: 500));
        return false;
      }

      final latest = release.cleanVersion;
      debugPrint('[UpdateGate] En son sürüm: $latest');

      if (currentVersion == null || !_isNewer(latest, currentVersion)) {
        _setStatus('Uygulama güncel (v$latest)');
        await Future.delayed(const Duration(milliseconds: 400));
        return false;
      }

      // Zip asset bul
      final asset = release.zipAsset;
      if (asset == null) {
        _setStatus('Yeni sürüm bulundu fakat paket eksik');
        await Future.delayed(const Duration(milliseconds: 500));
        return false;
      }

      _setStatus('Yeni sürüm bulundu: v$latest — indiriliyor...');
      _setProgress(0.0);

      // İndirme
      final tempDir = Directory.systemTemp;
      final stagingDir = Directory(
          '${tempDir.path}${Platform.pathSeparator}LocalHub_update_${DateTime.now().millisecondsSinceEpoch}');
      if (stagingDir.existsSync()) stagingDir.deleteSync(recursive: true);
      stagingDir.createSync(recursive: true);
      final zipPath =
          '${stagingDir.path}${Platform.pathSeparator}${asset.name}';

      await _downloadWithProgress(asset.downloadUrl, zipPath, asset.size);

      _setStatus('Paket çıkarılıyor...');
      _setProgress(null);
      final extractDir =
          Directory('${stagingDir.path}${Platform.pathSeparator}extracted');
      extractDir.createSync(recursive: true);
      await _extractZip(zipPath, extractDir.path);

      _setStatus('Güncelleme uygulanıyor...');
      // Apply script spawn et
      final installDir = File(Platform.resolvedExecutable).parent.path;
      final ok = await _spawnApplyScript(extractDir.path, installDir, latest);
      if (!ok) {
        _setStatus('Güncelleme uygulanamadı — devam ediliyor');
        await Future.delayed(const Duration(milliseconds: 800));
        return false;
      }

      _setStatus('Yeniden başlatılıyor...');
      _setProgress(1.0);
      // Apply script çalıştı — biz kapanıyoruz, o bizi yeniden başlatacak
      await Future.delayed(const Duration(milliseconds: 600));
      exit(0);
    } catch (e, st) {
      debugPrint('[UpdateGate] Güncelleme hatası: $e\n$st');
      _errorDetail = e.toString();
      _setStatus('Güncelleme başarısız — devam ediliyor');
      await Future.delayed(const Duration(milliseconds: 800));
      return false;
    }
  }

  String? _readCurrentVersion() {
    try {
      final dir = File(Platform.resolvedExecutable).parent.path;
      final f = File('$dir${Platform.pathSeparator}version.txt');
      if (!f.existsSync()) return null;
      return f.readAsStringSync().trim();
    } catch (_) {
      return null;
    }
  }

  Future<_Release?> _fetchLatestRelease() async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(Config.githubLatestReleaseUrl));
      req.headers.set('Accept', 'application/vnd.github+json');
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final body = await res.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      return _Release(
        tagName: (data['tag_name'] ?? '') as String,
        assets: ((data['assets'] as List?) ?? const [])
            .map((a) => _Asset(
                  name: (a['name'] ?? '') as String,
                  downloadUrl: (a['browser_download_url'] ?? '') as String,
                  size: (a['size'] as num?)?.toInt() ?? 0,
                ))
            .toList(),
      );
    } catch (e) {
      debugPrint('[UpdateGate] GitHub API hatası: $e');
      return null;
    } finally {
      client.close();
    }
  }

  bool _isNewer(String latest, String current) {
    try {
      final l = _parseVersion(latest);
      final c = _parseVersion(current);
      for (int i = 0; i < l.length && i < c.length; i++) {
        if (l[i] > c[i]) return true;
        if (l[i] < c[i]) return false;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  List<int> _parseVersion(String v) {
    final clean = v.split('-').first.split('+').first;
    return clean.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  }

  Future<void> _downloadWithProgress(
      String url, String dest, int totalSize) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}');
      }
      final sink = File(dest).openWrite();
      int received = 0;
      await for (final chunk in res) {
        sink.add(chunk);
        received += chunk.length;
        if (totalSize > 0) {
          final p = (received / totalSize).clamp(0.0, 1.0);
          _setProgress(p);
          final mbReceived = (received / 1024 / 1024).toStringAsFixed(1);
          final mbTotal = (totalSize / 1024 / 1024).toStringAsFixed(1);
          _setStatus(
              'İndiriliyor: $mbReceived / $mbTotal MB (${(p * 100).toStringAsFixed(0)}%)');
        }
      }
      await sink.close();
    } finally {
      client.close();
    }
  }

  Future<void> _extractZip(String zipPath, String destPath) async {
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      'Expand-Archive -Path "$zipPath" -DestinationPath "$destPath" -Force'
    ]);
    if (result.exitCode != 0) {
      throw Exception('Zip çıkarma hatası: ${result.stderr}');
    }
  }

  /// Batch (.cmd) file spawn ederek mevcut process'i bekler, robocopy ile
  /// dosyaları kopyalar, yeni exe'yi başlatır. Batch dosyası kullanmamızın
  /// sebebi: PowerShell ExecutionPolicy bazı sistemlerde imzasız .ps1
  /// dosyalarını sessizce blokluyor; .cmd dosyalarında bu sorun yok.
  /// Tüm aşamalar %TEMP%\LocalHub_apply.log dosyasına yazılır.
  Future<bool> _spawnApplyScript(
      String srcDir, String installDir, String newVersion) async {
    try {
      final currentPid = pid; // dart:io top-level
      const exeName = 'LocalHub.exe';
      final ts = DateTime.now().millisecondsSinceEpoch;
      final tempDir = Directory.systemTemp.path;
      final scriptPath = '$tempDir${Platform.pathSeparator}LocalHub_apply_$ts.cmd';
      final logPath = '$tempDir${Platform.pathSeparator}LocalHub_apply.log';

      // CMD batch script — execution policy sorunu yok, robocopy ile güvenilir
      // Dikkat: batch'te % işareti %% olarak escape edilir.
      final script = '''
@echo off
setlocal enableextensions
set "LOG=$logPath"
set "SRC=$srcDir"
set "DST=$installDir"
set "OLDPID=$currentPid"
set "EXE=$exeName"
set "NEWVER=$newVersion"

echo === LocalHub Apply Script === > "%LOG%"
echo Baslangic: %DATE% %TIME% >> "%LOG%"
echo SRC=%SRC% >> "%LOG%"
echo DST=%DST% >> "%LOG%"
echo OLDPID=%OLDPID% >> "%LOG%"
echo NEWVER=%NEWVER% >> "%LOG%"

REM Mevcut process bitsin — taskkill timeout dongusu (max 60sn)
set /a TRY=0
:WAITLOOP
tasklist /FI "PID eq %OLDPID%" /NH 2>nul | findstr /I "%EXE%" >nul
if errorlevel 1 goto AFTERWAIT
set /a TRY+=1
if %TRY% GEQ 60 (
    echo [UYARI] PID %OLDPID% 60sn icinde kapanmadi, taskkill deneniyor >> "%LOG%"
    taskkill /F /PID %OLDPID% >> "%LOG%" 2>&1
    timeout /t 2 /nobreak >nul
    goto AFTERWAIT
)
timeout /t 1 /nobreak >nul
goto WAITLOOP

:AFTERWAIT
echo Process kapandi (TRY=%TRY%). Dosyalar kopyalaniyor... >> "%LOG%"
timeout /t 1 /nobreak >nul

REM Robocopy: /E recursive (bos klasorler dahil), /IS include same files,
REM /IT include tweaked, /R:3 retry 3, /W:2 wait 2sn, /NFL /NDL kisa log
robocopy "%SRC%" "%DST%" /E /IS /IT /R:3 /W:2 /NFL /NDL /NJH /NJS >> "%LOG%" 2>&1
set RC=%ERRORLEVEL%
echo Robocopy exit code: %RC% >> "%LOG%"

REM Robocopy exit codes: 0-7 basarili, 8+ hatali
if %RC% GEQ 8 (
    echo [HATA] Robocopy basarisiz (kod %RC%) >> "%LOG%"
    goto END
)

REM version.txt yaz
echo|set /p="%NEWVER%" > "%DST%\\version.txt"
echo version.txt yazildi: %NEWVER% >> "%LOG%"

REM Yeni exe'yi baslat
if exist "%DST%\\%EXE%" (
    echo Yeni exe baslatiliyor: %DST%\\%EXE% >> "%LOG%"
    start "" /D "%DST%" "%DST%\\%EXE%"
    echo Baslatildi: %DATE% %TIME% >> "%LOG%"
) else (
    echo [HATA] Yeni exe bulunamadi: %DST%\\%EXE% >> "%LOG%"
)

:END
echo === Apply tamamlandi: %DATE% %TIME% === >> "%LOG%"

REM Cleanup: staging klasoru + bu script
timeout /t 2 /nobreak >nul
rmdir /S /Q "%SRC%" 2>nul
(goto) 2>nul & del "%~f0"
''';
      File(scriptPath).writeAsStringSync(script);
      debugPrint('[UpdateGate] Apply script yazildi: $scriptPath');
      debugPrint('[UpdateGate] Apply log dosyasi: $logPath');

      // CMD'yi Win32 CreateProcessW + CREATE_NO_WINDOW ile başlat —
      // Dart'ın Process.start detached mode'unda CREATE_NO_WINDOW flag'i
      // yok, bu yüzden cmd.exe görünür console penceresi açıyor.
      // invisibleSpawn (FFI) bu flag'i set eder → pencere açılmaz.
      final spawned = invisibleSpawn(
        r'C:\Windows\System32\cmd.exe',
        ['/c', scriptPath],
        tempDir,
      );
      if (!spawned) {
        debugPrint('[UpdateGate] invisibleSpawn basarisiz');
        return false;
      }
      debugPrint('[UpdateGate] Apply script invisible spawn edildi');

      // Spawn'in tetiklenmesi için kısa bir bekleme (script ilk satırı
      // log'a yazmaya başlayabilsin)
      await Future.delayed(const Duration(milliseconds: 500));

      // Verifikasyon: log dosyası oluşmuş mu?
      if (File(logPath).existsSync()) {
        debugPrint('[UpdateGate] Apply log dosyasi olusmus — script aktif');
      } else {
        debugPrint(
            '[UpdateGate] UYARI: Apply log dosyasi yok — script baslatilamamis olabilir');
      }
      return true;
    } catch (e, st) {
      debugPrint('[UpdateGate] Apply script spawn hatası: $e\n$st');
      return false;
    }
  }

  // ============================================================
  // Backend hazırlığı (eski davranış)
  // ============================================================

  Future<void> _waitForBackend() async {
    final host = await Storage.getServerHost();
    if (host == null || host.trim().isEmpty) {
      _setStatus('Sunucu ayarlı değil...');
      _setProgress(null);
      await Future.delayed(const Duration(milliseconds: 600));
      return;
    }

    _setStatus('Sunucu başlatılıyor...');
    _setProgress(null);

    if (await _isPort3000Ready()) {
      _setStatus('Sunucu hazır!');
      await Future.delayed(const Duration(milliseconds: 300));
      return;
    }

    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;

      if (await _isPort3000Ready()) {
        _setStatus('Sunucu hazır!');
        await Future.delayed(const Duration(milliseconds: 300));
        return;
      }

      final elapsed = 15 - deadline.difference(DateTime.now()).inSeconds;
      _setStatus('Sunucu başlatılıyor... (${elapsed}s)');
    }

    _setStatus('Sunucu bekleniyor (zaman aşımı)');
    await Future.delayed(const Duration(milliseconds: 500));
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

  // ============================================================
  // UI helpers
  // ============================================================

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  void _setProgress(double? p) {
    if (mounted) setState(() => _progress = p);
  }

  void _proceedToApp() {
    if (_proceeded || !mounted) return;
    _proceeded = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const Bootstrap()),
    );
  }

  // ============================================================
  // UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1F22),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // LocalHub logo — hub network konseptli, sürekli dönüyor
              Container(
                width: 110,
                height: 110,
                decoration: BoxDecoration(
                  color: const Color(0xFF202225),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color:
                          const Color(0xFF5865F2).withValues(alpha: 0.35),
                      blurRadius: 32,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: AnimatedBuilder(
                  animation: _spinCtrl,
                  builder: (context, _) {
                    return Transform.rotate(
                      angle: _spinCtrl.value * 2 * math.pi,
                      child: const _HubLogo(),
                    );
                  },
                ),
              ),
              const SizedBox(height: 28),
              const Text(
                'LocalHub',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Yerel ağ sohbeti',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: 300,
                child: LinearProgressIndicator(
                  minHeight: 6,
                  value: _progress,
                  backgroundColor: Colors.white12,
                  color: const Color(0xFF5865F2),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: 300,
                child: Text(
                  _status,
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
              if (_errorDetail != null) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: 300,
                  child: Text(
                    _errorDetail!,
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(color: Colors.white24, fontSize: 10),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              TextButton(
                onPressed: _proceedToApp,
                child: const Text(
                  'Atla ve devam et',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Release {
  final String tagName;
  final List<_Asset> assets;
  _Release({required this.tagName, required this.assets});

  String get cleanVersion {
    final t = tagName.trim();
    if (t.toLowerCase().startsWith('v')) return t.substring(1);
    return t;
  }

  _Asset? get zipAsset {
    for (final a in assets) {
      if (a.name.toLowerCase().endsWith('.zip')) return a;
    }
    return null;
  }
}

class _Asset {
  final String name;
  final String downloadUrl;
  final int size;
  _Asset({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });
}

/// Logo widget — programatik olarak hub network çizimi
/// (assets/app_icon.ico runtime'da Flutter Image'a yüklenemediği için
/// programatik CustomPaint kullanıyoruz)
class _HubLogo extends StatelessWidget {
  const _HubLogo();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _HubLogoPainter(),
    );
  }
}

class _HubLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final ringR = size.width * 0.32;
    final bigR = size.width * 0.12;
    final smallR = size.width * 0.08;

    final blurple = Paint()..color = const Color(0xFF5865F2);
    final blurpleLight = Paint()..color = const Color(0xFF7289DA);
    final white = Paint()..color = Colors.white;
    final green = Paint()..color = const Color(0xFF57F287);
    final linePaint = Paint()
      ..color = const Color(0xFF5865F2)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    // 4 satellite
    final sats = <Offset>[];
    for (int i = 0; i < 4; i++) {
      final ang = (math.pi / 4) + i * (math.pi / 2);
      sats.add(Offset(
        cx + ringR * math.cos(ang),
        cy + ringR * math.sin(ang),
      ));
    }

    // Bağlantılar
    for (final s in sats) {
      canvas.drawLine(Offset(cx, cy), s, linePaint);
    }
    // Satelliteler
    for (final s in sats) {
      canvas.drawCircle(s, smallR, blurpleLight);
      canvas.drawCircle(s, smallR * 0.5, white);
    }
    // Merkez
    canvas.drawCircle(Offset(cx, cy), bigR, blurple);
    canvas.drawCircle(Offset(cx, cy), bigR * 0.55, white);
    canvas.drawCircle(Offset(cx, cy), size.width * 0.025, green);
  }

  @override
  bool shouldRepaint(_HubLogoPainter oldDelegate) => false;
}
