import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// VOCAL-APP Updater — CLI uygulaması.
///
/// Akış:
///   1. Mevcut sürümü oku (install_dir/version.txt)
///   2. GitHub Releases API'den latest release'i çek
///   3. Yeni sürüm varsa zip'i indir → temp'e extract → install_dir'e kopyala
///   4. version.txt güncelle
///   5. discord_clone.exe'yi başlat, kendini kapat
///
/// Kullanım:
///   dart run bin\updater.dart [--install-dir C:\...\Release]
///   veya compile edilmiş: updater.exe --install-dir C:\...\Release

const String githubOwner = 'kabatay33';
const String githubRepo = 'VOCAL-APP';
const String githubLatestReleaseUrl =
    'https://api.github.com/repos/$githubOwner/$githubRepo/releases/latest';

final _logFile = File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}vocal_updater.log');

void log(String msg) {
  final ts = DateTime.now().toString().substring(0, 19);
  final line = '[$ts] $msg';
  // ignore: avoid_print
  print(line);
  try {
    _logFile.writeAsStringSync('$line\n', mode: FileMode.append);
  } catch (_) {}
}

Future<void> main(List<String> args) async {
  log('=== VOCAL-APP Updater başladı ===');

  // --install-dir argümanı veya varsayılan (updater'ın bulunduğu dizin)
  String installDir;
  final idx = args.indexOf('--install-dir');
  if (idx >= 0 && idx + 1 < args.length) {
    installDir = args[idx + 1];
  } else {
    // Updater exe'si install dir içinde çalışıyor olabilir (Release/)
    // veya development'ta updater/ altında
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    installDir = exeDir;
  }

  log('Install dir: $installDir');

  try {
    // 1) Mevcut sürümü oku
    final currentVersion = _readCurrentVersion(installDir);
    log('Mevcut sürüm: ${currentVersion ?? "bilinmiyor"}');

    // 2) GitHub'dan latest release
    log('GitHub\'dan sürüm kontrolü...');
    final release = await _fetchLatestRelease();
    if (release == null) {
      log('Release bulunamadı — mevcut sürümle devam');
      _launchApp(installDir);
      return;
    }

    final latestVersion = release.cleanVersion;
    log('Latest sürüm: $latestVersion');

    // 3) Karşılaştır
    if (currentVersion != null &&
        !_isNewer(latestVersion, currentVersion)) {
      log('Güncel — gerekli değil');
      _launchApp(installDir);
      return;
    }

    log('Yeni sürüm bulundu: $latestVersion (mevcut: ${currentVersion ?? "yok"})');

    // 4) Zip asset bul
    final zipAsset = release.zipAsset;
    if (zipAsset == null) {
      log('Release\'de .zip yok — atlanıyor');
      _launchApp(installDir);
      return;
    }

    // 5) İndir
    final tempDir = Directory.systemTemp;
    final stagingDir =
        Directory('${tempDir.path}${Platform.pathSeparator}vocal_update');
    if (stagingDir.existsSync()) {
      stagingDir.deleteSync(recursive: true);
    }
    stagingDir.createSync(recursive: true);

    final zipPath = '${stagingDir.path}${Platform.pathSeparator}${zipAsset.name}';
    log('İndiriliyor: ${zipAsset.downloadUrl}');
    await _downloadFile(zipAsset.downloadUrl, zipPath, zipAsset.size);
    log('İndirme tamamlandı');

    // 6) Extract
    log('Çıkarılıyor...');
    final extractDir =
        Directory('${stagingDir.path}${Platform.pathSeparator}extracted');
    extractDir.createSync(recursive: true);
    await _extractZip(zipPath, extractDir.path);
    log('Çıkarma tamamlandı');

    // 7) Kopyala (discord_clone.exe çalışıyorsa bekle)
    log('Uygulanıyor...');
    await _waitForAppExit(installDir);
    _copyRecursive(extractDir, installDir);
    log('Kopyalama tamamlandı');

    // 8) Version.txt güncelle
    _writeCurrentVersion(installDir, latestVersion);
    log('Sürüm güncellendi: $latestVersion');

    // 9) Temizlik
    try {
      stagingDir.deleteSync(recursive: true);
    } catch (_) {}

    // 10) Uygulamayı başlat
    _launchApp(installDir);
  } catch (e, st) {
    log('HATA: $e');
    log('Stack: $st');
    log('Mevcut sürümle devam ediliyor...');
    _launchApp(installDir);
  }
}

// ==================== Version ====================

String? _readCurrentVersion(String installDir) {
  final f = File('$installDir${Platform.pathSeparator}version.txt');
  if (!f.existsSync()) return null;
  return f.readAsStringSync().trim();
}

void _writeCurrentVersion(String installDir, String version) {
  final f = File('$installDir${Platform.pathSeparator}version.txt');
  f.writeAsStringSync(version);
}

// ==================== GitHub ====================

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
  _Asset(
      {required this.name, required this.downloadUrl, required this.size});
}

Future<_Release?> _fetchLatestRelease() async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(githubLatestReleaseUrl));
    req.headers.set('Accept', 'application/vnd.github+json');
    req.headers.set('X-GitHub-Api-Version', '2022-11-28');
    final res = await req.close().timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      log('GitHub API: HTTP ${res.statusCode}');
      return null;
    }
    final body = await res.transform(const SystemEncoding().decoder).join();
    final data = jsonDecode(body) as Map<String, dynamic>;
    return _Release(
      tagName: (data['tag_name'] ?? '') as String,
      name: (data['name'] ?? '') as String,
      draft: (data['draft'] as bool?) ?? false,
      prerelease: (data['prerelease'] as bool?) ?? false,
      assets: ((data['assets'] as List?) ?? const [])
          .map((a) => _Asset(
                name: (a['name'] ?? '') as String,
                downloadUrl: (a['browser_download_url'] ?? '') as String,
                size: (a['size'] as num?)?.toInt() ?? 0,
              ))
          .toList(),
    );
  } finally {
    client.close();
  }
}

// ==================== Download ====================

Future<void> _downloadFile(
    String url, String destPath, int expectedSize) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close().timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) {
      throw Exception('İndirme başarısız: HTTP ${res.statusCode}');
    }
    final sink = File(destPath).openWrite();
    int received = 0;
    await for (final chunk in res) {
      sink.add(chunk);
      received += chunk.length;
      if (expectedSize > 0) {
        final pct = (received / expectedSize * 100).toStringAsFixed(0);
        if (received % (256 * 1024) < chunk.length) {
          log('  İndirilen: $pct%');
        }
      }
    }
    await sink.close();
  } finally {
    client.close();
  }
}

// ==================== Extract ====================

Future<void> _extractZip(String zipPath, String destPath) async {
  // PowerShell Expand-Archive kullan (Windows'ta her zaman mevcut)
  final result = await Process.run(
    'powershell',
    [
      '-NoProfile',
      '-Command',
      'Expand-Archive -Path "$zipPath" -DestinationPath "$destPath" -Force'
    ],
    runInShell: false,
  );
  if (result.exitCode != 0) {
    throw Exception('Extract hatası: ${result.stderr}');
  }
}

// ==================== Copy & Launch ====================

Future<void> _waitForAppExit(String installDir) async {
  final exeName = 'discord_clone.exe';
  for (int i = 0; i < 30; i++) {
    if (!_isProcessRunning(exeName)) return;
    log('  $exeName hâlâ çalışıyor, bekleniyor...');
    await Future.delayed(const Duration(seconds: 1));
  }
  // Zorla kapat
  log('  $exeName zorla kapatılıyor...');
  try {
    await Process.run('taskkill', ['/F', '/IM', exeName], runInShell: false);
    await Future.delayed(const Duration(seconds: 1));
  } catch (_) {}
}

bool _isProcessRunning(String exeName) {
  try {
    final result = Process.runSync(
      'tasklist',
      ['/FI', 'IMAGENAME eq $exeName', '/NH'],
      runInShell: false,
      stdoutEncoding: const SystemEncoding(),
    );
    return (result.stdout as String).toLowerCase().contains(exeName.toLowerCase());
  } catch (_) {
    return false;
  }
}

void _copyRecursive(Directory src, String dest) {
  for (final entity in src.listSync(recursive: false)) {
    final name = entity.uri.pathSegments.last;
    final destPath = '$dest${Platform.pathSeparator}$name';
    if (entity is Directory) {
      final destDir = Directory(destPath);
      if (!destDir.existsSync()) destDir.createSync(recursive: true);
      _copyRecursive(entity, destPath);
    } else if (entity is File) {
      entity.copySync(destPath);
    }
  }
}

void _launchApp(String installDir) {
  final exePath = '$installDir${Platform.pathSeparator}discord_clone.exe';
  if (!File(exePath).existsSync()) {
    log('UYARI: $exePath bulunamadı!');
    return;
  }
  log('Başlatılıyor: $exePath');
  Process.start(
    exePath,
    [],
    mode: ProcessStartMode.detached,
    runInShell: false,
  );
  log('Uygulama başlatıldı.');
}

// ==================== Version Compare ====================

bool _isNewer(String latest, String current) {
  try {
    final l = _parseVersion(latest);
    final c = _parseVersion(current);
    for (int i = 0; i < 3; i++) {
      if (l[i] > c[i]) return true;
      if (l[i] < c[i]) return false;
    }
    return l[3] > c[3]; // build numarası
  } catch (_) {
    return false;
  }
}

List<int> _parseVersion(String version) {
  final buildSplit = version.split('+');
  final buildNum = buildSplit.length > 1 ? int.tryParse(buildSplit[1]) ?? 0 : 0;
  final clean = buildSplit.first.split('-').first;
  final parts = clean.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  while (parts.length < 3) parts.add(0);
  parts.add(buildNum);
  return parts;
}
