/// VOCAL-APP Updater (saf Dart, dart compile exe ile build edilir).
///
/// Akış:
///   1. Radmin VPN aktif değilse başlatmaya çalış (silent)
///   2. installDir tespit et (updater/ alt klasörü veya yanındaki exe)
///   3. GitHub Releases /latest çek
///   4. Mevcut version.txt ile karşılaştır
///   5. Yeni sürüm varsa indir + extract + kopyala + version.txt güncelle
///   6. discord_clone.exe başlat (cmd /c start ile detached) + exit
///
/// Önemli düzeltmeler:
///   - http paketi kullanılıyor (HttpClient yerine — redirect + stream daha
///     hızlı)
///   - Progress callback throttle edildi (sadece her ~200ms'de bir log)
///   - Download timeout ayrı, stream timeout daha uzun (60s → 5dk)
///   - cmd /c start ile detached spawn (sağlam launch)
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

// ==================== CONFIG ====================
const String githubOwner = 'kabatay33';
const String githubRepo = 'VOCAL-APP';
const String radminVpnPath = r'C:\Program Files (x86)\Radmin VPN\RvRvpnGui.exe';

// ==================== LOG ====================
late File _logFile;
void log(String msg) {
  final ts = DateTime.now().toIso8601String();
  try {
    _logFile.writeAsStringSync('[$ts] $msg\n', mode: FileMode.append);
  } catch (_) {}
  print(msg);
}

// ==================== MAIN ====================
Future<void> main() async {
  // Log dosyası — updater.exe'nin yanına. Konsol penceresi kapanırsa bile
  // dosyaya gider.
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  _logFile = File('$exeDir${Platform.pathSeparator}updater.log');
  try {
    if (_logFile.existsSync()) _logFile.deleteSync();
  } catch (_) {}

  log('=== VOCAL-APP UPDATER BASLADI ===');
  log('exe: ${Platform.resolvedExecutable}');
  log('cwd: ${Directory.current.path}');

  String installDir = exeDir;
  try {
    installDir = findInstallDir();
    log('installDir: $installDir');

    // 1. Radmin VPN (fire-and-forget, hata olursa devam et)
    ensureRadminVpn();

    // 2. Mevcut version
    final currentVersion = readVersion(installDir);
    log('Mevcut surum: ${currentVersion ?? "bilinmiyor"}');

    // 3. GitHub'dan latest release
    log('GitHub API: latest release alinyor...');
    final release = await fetchRelease()
        .timeout(const Duration(seconds: 15));
    if (release == null || release.tagName.isEmpty) {
      log('Release alinamadi, mevcut surumle devam.');
      await launchAndExit(installDir);
      return;
    }
    final latestVersion = release.cleanVersion;
    log('Son surum: $latestVersion');

    // 4. Comparison
    if (currentVersion != null && !isNewer(latestVersion, currentVersion)) {
      log('Uygulama guncel.');
      await launchAndExit(installDir);
      return;
    }
    final zipAsset = release.zipAsset;
    if (zipAsset == null) {
      log('Release\'de .zip asset yok.');
      await launchAndExit(installDir);
      return;
    }

    log('Yeni surum bulundu: $latestVersion (mevcut: $currentVersion)');
    log('Asset: ${zipAsset.name} (${zipAsset.size} bytes)');

    // 5. Download
    final tempDir = Directory.systemTemp;
    final staging = Directory(
        '${tempDir.path}${Platform.pathSeparator}vocal_update');
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);
    final zipPath = '${staging.path}${Platform.pathSeparator}${zipAsset.name}';

    log('Indirme baslatildi...');
    await downloadFile(zipAsset.downloadUrl, zipPath, zipAsset.size);
    log('Indirme tamam: $zipPath');

    // 6. Extract
    log('Extract...');
    final extractDir =
        Directory('${staging.path}${Platform.pathSeparator}extracted');
    extractDir.createSync(recursive: true);
    await extractZip(zipPath, extractDir.path);
    log('Extract OK');

    // 7. App'in kapanmasını bekle + kopyala
    log('discord_clone.exe kapanmasini bekleniyor...');
    await waitForAppExit();
    log('Kopyalama...');
    copyRecursive(extractDir, installDir);
    writeVersion(installDir, latestVersion);
    log('Kopyalama OK');

    // 8. Cleanup
    try {
      staging.deleteSync(recursive: true);
    } catch (_) {}

    log('Guncelleme tamamlandi -> $latestVersion');
  } catch (e, st) {
    log('HATA: $e');
    log('STACK: $st');
    // Yine de uygulamayı başlatmaya çalış (mevcut sürümle)
  }

  await launchAndExit(installDir);
}

// ==================== RADMIN VPN ====================
Future<void> ensureRadminVpn() async {
  try {
    if (isRunning('RvRvpnGui.exe')) {
      log('Radmin VPN zaten calisiyor');
      return;
    }
    final radmin = File(radminVpnPath);
    if (!radmin.existsSync()) {
      log('Radmin VPN bulunamadi: $radminVpnPath');
      return;
    }
    log('Radmin VPN baslatiliyor...');
    await Process.start(radminVpnPath, [],
        mode: ProcessStartMode.detached, runInShell: false);
  } catch (e) {
    log('Radmin VPN: $e');
  }
}

// ==================== INSTALL DIR ====================
String findInstallDir() {
  final exePath = Platform.resolvedExecutable;
  final exeDir = File(exePath).parent.path;

  // Senaryo 1: updater/ alt klasöründeyiz → üst klasör install dir
  if (exeDir.toLowerCase().endsWith('\\updater') ||
      exeDir.toLowerCase().endsWith('/updater')) {
    final parent = Directory(exeDir).parent.path;
    if (File('$parent\\discord_clone.exe').existsSync()) {
      return parent;
    }
  }

  // Senaryo 2: yanında discord_clone.exe var
  if (File('$exeDir\\discord_clone.exe').existsSync()) {
    return exeDir;
  }

  // Senaryo 3: üst klasörde
  final parent = Directory(exeDir).parent.path;
  if (File('$parent\\discord_clone.exe').existsSync()) {
    return parent;
  }

  // Fallback: exe dir
  return exeDir;
}

// ==================== VERSION ====================
String? readVersion(String dir) {
  final f = File('$dir\\version.txt');
  if (!f.existsSync()) return null;
  return f.readAsStringSync().trim();
}

void writeVersion(String dir, String version) {
  File('$dir\\version.txt').writeAsStringSync(version);
}

// ==================== GITHUB ====================
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

Future<_Release?> fetchRelease() async {
  try {
    final res = await http.get(
      Uri.parse(
          'https://api.github.com/repos/$githubOwner/$githubRepo/releases/latest'),
      headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'vocal-updater',
      },
    ).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      log('GitHub API: HTTP ${res.statusCode}');
      return null;
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
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
    log('GitHub API hata: $e');
    return null;
  }
}

// ==================== DOWNLOAD ====================
/// http.Client().send() ile streaming download. Progress throttle: her ~200ms'de
/// bir log yazılır (her chunk'ta değil — eski kodu yavaşlatan buydu).
Future<void> downloadFile(String url, String destPath, int expectedSize) async {
  final client = http.Client();
  IOSink? sink;
  try {
    final req = http.Request('GET', Uri.parse(url));
    req.headers['User-Agent'] = 'vocal-updater';
    final res = await client.send(req).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}');
    }
    final total = res.contentLength ?? expectedSize;
    sink = File(destPath).openWrite();
    var received = 0;
    var lastLogMs = DateTime.now().millisecondsSinceEpoch;
    await for (final chunk in res.stream) {
      sink.add(chunk);
      received += chunk.length;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastLogMs >= 250) {
        lastLogMs = now;
        if (total > 0) {
          final pct = (received * 100 / total).toStringAsFixed(0);
          final mb = (received / 1024 / 1024).toStringAsFixed(1);
          final totalMb = (total / 1024 / 1024).toStringAsFixed(1);
          log('Indirme: $pct% ($mb / $totalMb MB)');
        } else {
          final mb = (received / 1024 / 1024).toStringAsFixed(1);
          log('Indirme: $mb MB');
        }
      }
    }
    await sink.flush();
    await sink.close();
    sink = null;
    log('Toplam indirilen: $received bytes');
  } finally {
    try {
      await sink?.close();
    } catch (_) {}
    client.close();
  }
}

// ==================== EXTRACT ====================
Future<void> extractZip(String zipPath, String destPath) async {
  final result = await Process.run('powershell', [
    '-NoProfile',
    '-Command',
    'Expand-Archive -Path "$zipPath" -DestinationPath "$destPath" -Force'
  ]);
  if (result.exitCode != 0) {
    throw Exception('Expand-Archive: ${result.stderr}');
  }
}

// ==================== WAIT APP EXIT ====================
Future<void> waitForAppExit() async {
  for (int i = 0; i < 30; i++) {
    if (!isRunning('discord_clone.exe')) return;
    await Future.delayed(const Duration(seconds: 1));
  }
  log('discord_clone.exe hala calisiyor, zorla kapatiliyor...');
  try {
    await Process.run('taskkill', ['/F', '/IM', 'discord_clone.exe']);
    await Future.delayed(const Duration(seconds: 1));
  } catch (e) {
    log('taskkill: $e');
  }
}

// ==================== TASK CHECK ====================
bool isRunning(String name) {
  try {
    final r = Process.runSync(
      'tasklist',
      ['/FI', 'IMAGENAME eq $name', '/NH'],
      runInShell: false,
    );
    return (r.stdout as String).toLowerCase().contains(name.toLowerCase());
  } catch (_) {
    return false;
  }
}

// ==================== COPY ====================
/// Kaynak klasördeki tüm dosya/klasörü hedef üzerine kopyala.
/// Kaynak içinde "updater" klasörü varsa onu DA kopyala (updater kendisini
/// de güncelleyebilsin). Kendine yazma hatası önlemek için kaynak ve hedef
/// aynı yer ise atla.
void copyRecursive(Directory src, String dest) {
  Directory(dest).createSync(recursive: true);
  for (final entity in src.listSync(recursive: false)) {
    final name = entity.uri.pathSegments
        .where((s) => s.isNotEmpty)
        .last;
    final targetPath = '$dest\\$name';
    try {
      if (entity is Directory) {
        copyRecursive(entity, targetPath);
      } else if (entity is File) {
        // updater kendi exe'sini overwrite edemez — atla, sonra
        // post-update task replace edebilir
        if (entity.path.toLowerCase().endsWith('updater.exe') &&
            File(targetPath).path.toLowerCase() ==
                Platform.resolvedExecutable.toLowerCase()) {
          log('Kendi updater.exe atlandi (sonra replace edilebilir)');
          continue;
        }
        try {
          entity.copySync(targetPath);
        } catch (e) {
          log('Kopyalama hatasi $name: $e (devam)');
        }
      }
    } catch (e) {
      log('Atlanan $name: $e');
    }
  }
}

// ==================== LAUNCH + EXIT ====================
Future<void> launchAndExit(String installDir) async {
  final exePath = '$installDir\\discord_clone.exe';
  log('Baslatiliyor: $exePath');
  if (!File(exePath).existsSync()) {
    log('HATA: discord_clone.exe bulunamadi: $exePath');
    log('Cikiyor (5 sn sonra)...');
    await Future.delayed(const Duration(seconds: 5));
    exit(1);
  }

  // discord_clone'u VOCAL_NO_UPDATER=1 env ile başlat ki updater'ı yeniden
  // tetiklemesin (endless loop önleme).
  // Flutter Windows runner command-line args'ı engine'e iletmediği için
  // env var kullanıyoruz.
  final env = {'VOCAL_NO_UPDATER': '1'};
  try {
    await Process.start(
      exePath,
      const [],
      workingDirectory: installDir,
      environment: env,
      includeParentEnvironment: true,
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
    log('discord_clone.exe baslatildi (VOCAL_NO_UPDATER=1)');
  } catch (e) {
    log('Spawn hatasi: $e');
  }

  // Updater kendisini exit'leyecek
  await Future.delayed(const Duration(milliseconds: 500));
  exit(0);
}

// ==================== VERSION COMPARE ====================
bool isNewer(String latest, String current) {
  try {
    final l = parseVersion(latest);
    final c = parseVersion(current);
    for (int i = 0; i < 3; i++) {
      if (l[i] > c[i]) return true;
      if (l[i] < c[i]) return false;
    }
    return l[3] > c[3];
  } catch (_) {
    return false;
  }
}

List<int> parseVersion(String v) {
  final bs = v.split('+');
  final bn = bs.length > 1 ? int.tryParse(bs[1]) ?? 0 : 0;
  final clean = bs.first.split('-').first;
  final parts =
      clean.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  while (parts.length < 3) {
    parts.add(0);
  }
  parts.add(bn);
  return parts;
}
