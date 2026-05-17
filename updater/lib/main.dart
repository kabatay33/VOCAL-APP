import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const String githubOwner = 'kabatay33';
const String githubRepo = 'VOCAL-APP';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const UpdaterApp());
}

class UpdaterApp extends StatelessWidget {
  const UpdaterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF1E1F22),
      ),
      home: const UpdaterScreen(),
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
  _Asset({required this.name, required this.downloadUrl, required this.size});
}

enum _State { checking, upToDate, downloading, applying, done, error }

class UpdaterScreen extends StatefulWidget {
  const UpdaterScreen({super.key});

  @override
  State<UpdaterScreen> createState() => _UpdaterScreenState();
}

class _UpdaterScreenState extends State<UpdaterScreen> {
  _State _state = _State.checking;
  String _status = 'Sürüm kontrolü yapılıyor...';
  String? _currentVersion;
  String? _latestVersion;
  double _progress = 0;
  String? _errorDetail;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  /// Install directory'yi bul: discord_clone.exe'nin olduğu yer
  String _findInstallDir() {
    final exePath = Platform.resolvedExecutable;
    final exeDir = File(exePath).parent.path;

    // 1) updater/ alt klasöründeysek üst klasöre bak
    if (exeDir.endsWith('\\updater') || exeDir.endsWith('/updater')) {
      final parent = Directory(exeDir).parent?.path;
      if (parent != null) {
        final candidate = '$parent\\discord_clone.exe';
        if (File(candidate).existsSync()) {
          debugPrint('[UPDATER] installDir (parent): $parent');
          return parent;
        }
      }
    }

    // 2) Aynı dizinde discord_clone.exe var mı?
    final sameDir = '$exeDir\\discord_clone.exe';
    if (File(sameDir).existsSync()) {
      debugPrint('[UPDATER] installDir (same): $exeDir');
      return exeDir;
    }

    // 3) Üst klasöre bak
    final parentDir = Directory(exeDir).parent?.path;
    if (parentDir != null) {
      final parentCandidate = '$parentDir\\discord_clone.exe';
      if (File(parentCandidate).existsSync()) {
        debugPrint('[UPDATER] installDir (grandparent): $parentDir');
        return parentDir;
      }
    }

    // 4) Bulamadık, olduğumuz yeri döndür
    debugPrint('[UPDATER] discord_clone.exe bulunamadı, exeDir kullanılıyor: $exeDir');
    return exeDir;
  }

  Future<void> _run() async {
    try {
      // 1. Radmin VPN kontrol
      await _ensureRadminVpn();

      // 2. Mevcut versiyonu oku
      final installDir = _findInstallDir();
      _currentVersion = _readVersion(installDir);
      debugPrint('[UPDATER] Mevcut sürüm: $_currentVersion');
      debugPrint('[UPDATER] Install dir: $installDir');

      setState(() {
        _status = 'Mevcut sürüm: ${_currentVersion ?? "bilinmiyor"}\nGitHub kontrol ediliyor...';
      });

      await Future.delayed(const Duration(milliseconds: 500));

      // 3. GitHub'dan son sürümü al
      final release = await _fetchRelease();
      if (release == null) {
        // GitHub'a bağlanılamadı — mevcut sürümle devam
        setState(() {
          _state = _State.error;
          _status = 'GitHub\'a bağlanılamadı';
          _errorDetail = 'Mevcut sürümle devam ediliyor';
        });
        await Future.delayed(const Duration(seconds: 2));
        _launchAndExit(installDir);
        return;
      }

      _latestVersion = release.cleanVersion;
      debugPrint('[UPDATER] Son sürüm: $_latestVersion');

      // 4. Versiyon karşılaştırması
      if (_currentVersion != null && !_isNewer(_latestVersion!, _currentVersion!)) {
        setState(() {
          _state = _State.upToDate;
          _status = 'Uygulama güncel!';
          _errorDetail = 'Sürüm: $_currentVersion';
        });
        await Future.delayed(const Duration(seconds: 1));
        _launchAndExit(installDir);
        return;
      }

      // 5. Yeni sürüm var — indir
      final zipAsset = release.zipAsset;
      if (zipAsset == null) {
        setState(() {
          _state = _State.error;
          _status = 'Release\'de .zip dosyası yok';
          _errorDetail = 'Mevcut sürümle devam';
        });
        await Future.delayed(const Duration(seconds: 2));
        _launchAndExit(installDir);
        return;
      }

      setState(() {
        _state = _State.downloading;
        _status = 'Güncelleme indiriliyor...';
        _errorDetail = 'Sürüm $_latestVersion';
        _progress = 0;
      });

      final tempDir = Directory.systemTemp;
      final staging = Directory('${tempDir.path}${Platform.pathSeparator}vocal_update');
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      staging.createSync(recursive: true);
      final zipPath = '${staging.path}${Platform.pathSeparator}${zipAsset.name}';

      await _download(zipAsset.downloadUrl, zipPath, zipAsset.size, (p) {
        if (mounted) setState(() => _progress = p);
      });

      // 6. Çıkar
      setState(() {
        _state = _State.applying;
        _status = 'Güncelleme uygulanıyor...';
        _errorDetail = null;
      });

      final extractDir = Directory('${staging.path}${Platform.pathSeparator}extracted');
      extractDir.createSync(recursive: true);
      await _extractZip(zipPath, extractDir.path);

      // 7. Uygula
      await _waitForAppExit();
      _copyRecursive(extractDir, installDir);
      _writeVersion(installDir, _latestVersion!);
      try { staging.deleteSync(recursive: true); } catch (_) {}

      setState(() {
        _state = _State.done;
        _status = 'Güncelleme tamamlandı!';
        _errorDetail = 'Yeni sürüm: $_latestVersion';
      });

      await Future.delayed(const Duration(seconds: 1));
      _launchAndExit(installDir);
    } catch (e) {
      debugPrint('[UPDATER] HATA: $e');
      setState(() {
        _state = _State.error;
        _status = 'Hata oluştu';
        _errorDetail = '$e\nMevcut sürümle devam ediliyor...';
      });
      await Future.delayed(const Duration(seconds: 3));
      _launchAndExit(_findInstallDir());
    }
  }

  Future<void> _ensureRadminVpn() async {
    try {
      if (_isRunning('RvRvpnGui.exe')) {
        debugPrint('[UPDATER] Radmin VPN zaten çalışıyor');
        return;
      }
      const radminPath = r'C:\Program Files (x86)\Radmin VPN\RvRvpnGui.exe';
      final radminExe = File(radminPath);
      if (await radminExe.exists()) {
        debugPrint('[UPDATER] Radmin VPN başlatılıyor...');
        Process.start(radminPath, [], mode: ProcessStartMode.detached, runInShell: false);
        await Future.delayed(const Duration(seconds: 3));
      } else {
        debugPrint('[UPDATER] Radmin VPN bulunamadı');
      }
    } catch (e) {
      debugPrint('[UPDATER] Radmin VPN hatası: $e');
    }
  }

  void _launchAndExit(String installDir) {
    final exePath = '$installDir\\discord_clone.exe';
    debugPrint('[UPDATER] Başlatılıyor: $exePath');

    if (File(exePath).existsSync()) {
      try {
        Process.start(exePath, [], mode: ProcessStartMode.detached, runInShell: false);
        debugPrint('[UPDATER] discord_clone.exe başlatıldı');
      } catch (e) {
        debugPrint('[UPDATER] Başlatma hatası: $e');
      }
    } else {
      debugPrint('[UPDATER] discord_clone.exe BULUNAMADI: $exePath');
    }

    // Pencereyi kapat ve çık
    try {
      SystemNavigator.pop();
    } catch (_) {}
    // 500ms sonra zorla çık
    Future.delayed(const Duration(milliseconds: 500), () => exit(0));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1F22),
      body: Column(
        children: [
          // Title bar
          Container(
            height: 36,
            color: const Color(0xFF1A1B1E),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                const Icon(Icons.system_update, color: Color(0xFF5865F2), size: 16),
                const SizedBox(width: 8),
                const Text('VOCAL-APP Updater',
                    style: TextStyle(color: Colors.white70, fontSize: 12)),
                const Spacer(),
                GestureDetector(
                  onTap: () => exit(0),
                  child: Container(
                    width: 28, height: 28,
                    alignment: Alignment.center,
                    child: const Icon(Icons.close, size: 16, color: Colors.white54),
                  ),
                ),
              ],
            ),
          ),
          // Content
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 64, height: 64,
                      decoration: BoxDecoration(
                        color: const Color(0xFF5865F2),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF5865F2).withValues(alpha: 0.4),
                            blurRadius: 20, spreadRadius: 1,
                          ),
                        ],
                      ),
                      child: Icon(_iconForState(), color: Colors.white, size: 32),
                    ),
                    const SizedBox(height: 24),
                    if (_state == _State.downloading) ...[
                      SizedBox(
                        width: 260,
                        child: LinearProgressIndicator(
                          value: _progress, minHeight: 6,
                          backgroundColor: Colors.white12,
                          color: const Color(0xFF5865F2),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text('${(_progress * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    ] else if (_state == _State.checking || _state == _State.applying) ...[
                      const SizedBox(
                        width: 260,
                        child: LinearProgressIndicator(
                          minHeight: 6,
                          backgroundColor: Colors.white12,
                          color: Color(0xFF5865F2),
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: 6),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      _status,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _state == _State.error ? Colors.redAccent : Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                    if (_errorDetail != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _errorDetail!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  IconData _iconForState() {
    switch (_state) {
      case _State.checking: return Icons.cloud_sync;
      case _State.upToDate: return Icons.check_circle;
      case _State.downloading: return Icons.downloading;
      case _State.applying: return Icons.install_desktop;
      case _State.done: return Icons.check_circle;
      case _State.error: return Icons.error_outline;
    }
  }

  String? _readVersion(String dir) {
    final f = File('$dir\\version.txt');
    if (!f.existsSync()) return null;
    return f.readAsStringSync().trim();
  }

  void _writeVersion(String dir, String version) {
    final f = File('$dir\\version.txt');
    f.writeAsStringSync(version);
  }

  Future<_Release?> _fetchRelease() async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(
          Uri.parse('https://api.github.com/repos/$githubOwner/$githubRepo/releases/latest'));
      req.headers.set('Accept', 'application/vnd.github+json');
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(await res.transform(const SystemEncoding().decoder).join())
          as Map<String, dynamic>;
      return _Release(
        tagName: (data['tag_name'] ?? '') as String,
        assets: ((data['assets'] as List?) ?? const []).map((a) => _Asset(
          name: (a['name'] ?? '') as String,
          downloadUrl: (a['browser_download_url'] ?? '') as String,
          size: (a['size'] as num?)?.toInt() ?? 0,
        )).toList(),
      );
    } finally {
      client.close();
    }
  }

  Future<void> _download(
      String url, String dest, int total, void Function(double) onProgress) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final sink = File(dest).openWrite();
      int received = 0;
      await for (final chunk in res) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress(received / total);
      }
      await sink.close();
    } finally {
      client.close();
    }
  }

  Future<void> _extractZip(String zipPath, String destPath) async {
    final result = await Process.run('powershell', [
      '-NoProfile', '-Command',
      'Expand-Archive -Path "$zipPath" -DestinationPath "$destPath" -Force'
    ]);
    if (result.exitCode != 0) throw Exception('Extract: ${result.stderr}');
  }

  Future<void> _waitForAppExit() async {
    for (int i = 0; i < 30; i++) {
      if (!_isRunning('discord_clone.exe')) return;
      await Future.delayed(const Duration(seconds: 1));
    }
    try {
      await Process.run('taskkill', ['/F', '/IM', 'discord_clone.exe']);
      await Future.delayed(const Duration(seconds: 1));
    } catch (_) {}
  }

  bool _isRunning(String name) {
    try {
      final r = Process.runSync('tasklist', ['/FI', 'IMAGENAME eq $name', '/NH'], runInShell: false);
      return (r.stdout as String).toLowerCase().contains(name.toLowerCase());
    } catch (_) {
      return false;
    }
  }

  void _copyRecursive(Directory src, String dest) {
    for (final e in src.listSync(recursive: false)) {
      final name = e.uri.pathSegments.last;
      final dp = '$dest\\$name';
      if (e is Directory) {
        Directory(dp).createSync(recursive: true);
        _copyRecursive(e, dp);
      } else if (e is File) {
        e.copySync(dp);
      }
    }
  }

  bool _isNewer(String latest, String current) {
    try {
      final l = _parse(latest);
      final c = _parse(current);
      for (int i = 0; i < 3; i++) {
        if (l[i] > c[i]) return true;
        if (l[i] < c[i]) return false;
      }
      return l[3] > c[3];
    } catch (_) {
      return false;
    }
  }

  List<int> _parse(String v) {
    final bs = v.split('+');
    final bn = bs.length > 1 ? int.tryParse(bs[1]) ?? 0 : 0;
    final clean = bs.first.split('-').first;
    final parts = clean.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    while (parts.length < 3) parts.add(0);
    parts.add(bn);
    return parts;
  }
}
