import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';

const String githubOwner = 'kabatay33';
const String githubRepo = 'VOCAL-APP';

void main() {
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
  final String name;
  final bool draft;
  final bool prerelease;
  final List<_Asset> assets;
  _Release({
    required this.tagName,
    required this.name,
    required this.draft,
    required this.prerelease,
    required this.assets,
  });
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  String get _installDir => File(Platform.resolvedExecutable).parent.path;

  Future<void> _run() async {
    try {
      _currentVersion = _readVersion();
      setState(() {
        _status = 'Mevcut sürüm: ${_currentVersion ?? "bilinmiyor"}\nGitHub kontrol ediliyor...';
      });

      await Future.delayed(const Duration(milliseconds: 500));

      final release = await _fetchRelease();
      if (release == null) {
        setState(() {
          _state = _State.error;
          _status = 'GitHub\'a bağlanılamadı\nMevcut sürümle devam ediliyor';
        });
        await Future.delayed(const Duration(seconds: 2));
        _launchAndExit();
        return;
      }

      _latestVersion = release.cleanVersion;

      if (_currentVersion != null && !_isNewer(_latestVersion!, _currentVersion!)) {
        setState(() {
          _state = _State.upToDate;
          _status = 'Uygulama güncel!\nSürüm: $_currentVersion';
        });
        await Future.delayed(const Duration(seconds: 1));
        _launchAndExit();
        return;
      }

      // Yeni sürüm var
      final zipAsset = release.zipAsset;
      if (zipAsset == null) {
        setState(() {
          _state = _State.error;
          _status = 'Release\'de .zip dosyası yok\nMevcut sürümle devam';
        });
        await Future.delayed(const Duration(seconds: 2));
        _launchAndExit();
        return;
      }

      // İndir
      setState(() {
        _state = _State.downloading;
        _status = 'Güncelleme indiriliyor...\n$_latestVersion';
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

      // Extract
      setState(() {
        _state = _State.applying;
        _status = 'Güncelleme uygulanıyor...';
      });

      final extractDir = Directory('${staging.path}${Platform.pathSeparator}extracted');
      extractDir.createSync(recursive: true);
      await _extractZip(zipPath, extractDir.path);

      // Uygula
      await _waitForAppExit();
      _copyRecursive(extractDir, _installDir);
      _writeVersion(_latestVersion!);

      try { staging.deleteSync(recursive: true); } catch (_) {}

      setState(() {
        _state = _State.done;
        _status = 'Güncelleme tamamlandı!\nYeni sürüm: $_latestVersion';
      });

      await Future.delayed(const Duration(seconds: 1));
      _launchAndExit();
    } catch (e) {
      setState(() {
        _state = _State.error;
        _status = 'Hata: $e\nMevcut sürümle devam ediliyor...';
      });
      await Future.delayed(const Duration(seconds: 2));
      _launchAndExit();
    }
  }

  void _launchAndExit() {
    final exePath = '$_installDir${Platform.pathSeparator}discord_clone.exe';
    if (File(exePath).existsSync()) {
      Process.start(exePath, [], mode: ProcessStartMode.detached, runInShell: false);
    }
    exit(0);
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
                    const SizedBox(height: 20),
                    if (_state == _State.upToDate || _state == _State.done)
                      FilledButton.icon(
                        onPressed: _launchAndExit,
                        icon: const Icon(Icons.play_arrow, size: 18),
                        label: const Text('Uygulamayı Başlat'),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF5865F2),
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        ),
                      ),
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

  // ==================== Version ====================

  String? _readVersion() {
    final f = File('$_installDir${Platform.pathSeparator}version.txt');
    if (!f.existsSync()) return null;
    return f.readAsStringSync().trim();
  }

  void _writeVersion(String version) {
    final f = File('$_installDir${Platform.pathSeparator}version.txt');
    f.writeAsStringSync(version);
  }

  // ==================== GitHub ====================

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
        name: (data['name'] ?? '') as String,
        draft: (data['draft'] as bool?) ?? false,
        prerelease: (data['prerelease'] as bool?) ?? false,
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

  // ==================== Download ====================

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

  // ==================== Extract & Apply ====================

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
      final dp = '$dest${Platform.pathSeparator}$name';
      if (e is Directory) {
        Directory(dp).createSync(recursive: true);
        _copyRecursive(e, dp);
      } else if (e is File) {
        e.copySync(dp);
      }
    }
  }

  // ==================== Version Compare ====================

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
