import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

// ==================== CONFIG ====================
const String githubOwner = 'kabatay33';
const String githubRepo = 'VOCAL-APP';
const String radminVpnPath = r'C:\Program Files (x86)\Radmin VPN\RvRvpnGui.exe';

// ==================== LOG ====================
void log(String msg) {
  final f = File('${Directory.current.path}\\updater.log');
  f.writeAsStringSync('${DateTime.now()} $msg\n', mode: FileMode.append);
  print(msg);
}

// ==================== MAIN ====================
Future<void> main() async {
  log('=== VOCAL-APP UPDATER BASLADI ===');
  log('exe: ${Platform.resolvedExecutable}');
  log('cwd: ${Directory.current.path}');

  try {
    // 1. Radmin VPN kontrol
    await ensureRadminVpn();

    // 2. Install dir bul
    final installDir = findInstallDir();
    log('installDir: $installDir');

    // 3. Mevcut versiyonu oku
    final currentVersion = readVersion(installDir);
    log('Mevcut surum: ${currentVersion ?? "bilinmiyor"}');

    // 4. GitHub'dan son surumu al
    log('GitHub API cagriliyor...');
    final release = await fetchRelease();
    if (release == null) {
      log('GitHub API basarisiz, mevcut surumle devam');
      await Future.delayed(Duration(seconds: 2));
      await launchAndExit(installDir);
      return;
    }

    final latestVersion = release.cleanVersion;
    log('Son surum: $latestVersion');

    // 5. Versiyon karsilastirmasi
    if (currentVersion != null && !isNewer(latestVersion, currentVersion)) {
      log('Uygulama guncel! Surum: $currentVersion');
      await Future.delayed(Duration(seconds: 1));
      await launchAndExit(installDir);
      return;
    }

    // 6. Yeni surum var - indir
    log('Yeni surum bulundu: $latestVersion');
    final zipAsset = release.zipAsset;
    if (zipAsset == null) {
      log('Release\'de .zip dosyasi yok, mevcut surumle devam');
      await Future.delayed(Duration(seconds: 2));
      await launchAndExit(installDir);
      return;
    }

    // 7. Indir
    log('Indiriliyor: ${zipAsset.name}');
    final tempDir = Directory.systemTemp;
    final staging = Directory('${tempDir.path}${Platform.pathSeparator}vocal_update');
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);
    final zipPath = '${staging.path}${Platform.pathSeparator}${zipAsset.name}';

    await download(zipAsset.downloadUrl, zipPath, zipAsset.size, (p) {
      stdout.write('\rIndiriliyor: ${(p * 100).toStringAsFixed(0)}%');
    });
    log('\nIndirme tamamlandi');

    // 8. Cikar
    log('Cikariliyor...');
    final extractDir = Directory('${staging.path}${Platform.pathSeparator}extracted');
    extractDir.createSync(recursive: true);
    await extractZip(zipPath, extractDir.path);

    // 9. Uygula
    log('Uygulanuyor...');
    await waitForAppExit();
    copyRecursive(extractDir, installDir);
    writeVersion(installDir, latestVersion);
    try { staging.deleteSync(recursive: true); } catch (_) {}

    log('Guncelleme tamamlandi! Yeni surum: $latestVersion');
    await Future.delayed(Duration(seconds: 1));
    launchAndExit(installDir);
  } catch (e, st) {
    log('HATA: $e');
    log('STACK: $st');
    await Future.delayed(Duration(seconds: 3));
    launchAndExit(findInstallDir());
  }
}

// ==================== RADMIN VPN ====================
Future<void> ensureRadminVpn() async {
  try {
    if (isRunning('RvRvpnGui.exe')) {
      log('Radmin VPN zaten calisiyor');
      return;
    }
    final radminExe = File(radminVpnPath);
    if (await radminExe.exists()) {
      log('Radmin VPN baslatiliyor...');
      Process.start(radminVpnPath, [], mode: ProcessStartMode.detached, runInShell: false);
      await Future.delayed(Duration(seconds: 3));
    } else {
      log('Radmin VPN bulunamadi');
    }
  } catch (e) {
    log('Radmin VPN hatasi: $e');
  }
}

// ==================== INSTALL DIR ====================
String findInstallDir() {
  final exePath = Platform.resolvedExecutable;
  final exeDir = File(exePath).parent.path;

  // 1) updater/ alt klasorundeyse ust klasore bak
  if (exeDir.endsWith('\\updater') || exeDir.endsWith('/updater')) {
    final parent = Directory(exeDir).parent?.path;
    if (parent != null) {
      final candidate = '$parent\\discord_clone.exe';
      if (File(candidate).existsSync()) return parent;
    }
  }

  // 2) Ayni dizinde discord_clone.exe var mi?
  final sameDir = '$exeDir\\discord_clone.exe';
  if (File(sameDir).existsSync()) return exeDir;

  // 3) Ust klasore bak
  final parentDir = Directory(exeDir).parent?.path;
  if (parentDir != null) {
    final parentCandidate = '$parentDir\\discord_clone.exe';
    if (File(parentCandidate).existsSync()) return parentDir;
  }

  return exeDir;
}

// ==================== VERSION ====================
String? readVersion(String dir) {
  final f = File('$dir\\version.txt');
  if (!f.existsSync()) return null;
  return f.readAsStringSync().trim();
}

void writeVersion(String dir, String version) {
  final f = File('$dir\\version.txt');
  f.writeAsStringSync(version);
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
  final client = HttpClient();
  try {
    final req = await client.getUrl(
        Uri.parse('https://api.github.com/repos/$githubOwner/$githubRepo/releases/latest'));
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close().timeout(Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final data = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
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

// ==================== DOWNLOAD ====================
Future<void> download(String url, String dest, int total, void Function(double) onProgress) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close().timeout(Duration(seconds: 60));
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

// ==================== EXTRACT & APPLY ====================
Future<void> extractZip(String zipPath, String destPath) async {
  final result = await Process.run('powershell', [
    '-NoProfile', '-Command',
    'Expand-Archive -Path "$zipPath" -DestinationPath "$destPath" -Force'
  ]);
  if (result.exitCode != 0) throw Exception('Extract: ${result.stderr}');
}

Future<void> waitForAppExit() async {
  for (int i = 0; i < 30; i++) {
    if (!isRunning('discord_clone.exe')) return;
    await Future.delayed(Duration(seconds: 1));
  }
  try {
    await Process.run('taskkill', ['/F', '/IM', 'discord_clone.exe']);
    await Future.delayed(Duration(seconds: 1));
  } catch (_) {}
}

bool isRunning(String name) {
  try {
    final r = Process.runSync('tasklist', ['/FI', 'IMAGENAME eq $name', '/NH'], runInShell: false);
    return (r.stdout as String).toLowerCase().contains(name.toLowerCase());
  } catch (_) {
    return false;
  }
}

void copyRecursive(Directory src, String dest) {
  for (final e in src.listSync(recursive: false)) {
    final name = e.uri.pathSegments.last;
    final dp = '$dest\\$name';
    if (e is Directory) {
      Directory(dp).createSync(recursive: true);
      copyRecursive(e, dp);
    } else if (e is File) {
      e.copySync(dp);
    }
  }
}

// ==================== LAUNCH ====================
Future<void> launchAndExit(String installDir) async {
  final exePath = '$installDir\\discord_clone.exe';
  log('Baslatiliyor: $exePath');

  final exeFile = File(exePath);
  log('discord_clone.exe var mi: ${exeFile.existsSync()}');

  if (exeFile.existsSync()) {
    log('discord_clone.exe boyut: ${exeFile.lengthSync()} bytes');
    log('installDir var mi: ${Directory(installDir).existsSync()}');

    // Yontem 1: cmd /c start
    log('Yontem 1: cmd /c start deneniyor...');
    try {
      final r1 = Process.runSync('cmd', ['/c', 'start', '""', '/d', installDir, exePath]);
      log('cmd start exit: ${r1.exitCode}');
    } catch (e) {
      log('cmd start hata: $e');
    }

    // Yontem 2: ShellExecute
    log('Yontem 2: ShellExecute deneniyor...');
    try {
      final exePathW = exePath.toNativeUtf16();
      final dirW = installDir.toNativeUtf16();
      final result = ShellExecute(
        NULL,
        'open'.toNativeUtf16(),
        exePathW,
        nullptr,
        dirW,
        SW_SHOWNORMAL,
      );
      calloc.free(exePathW);
      calloc.free(dirW);
      log('ShellExecute sonucu: $result');
    } catch (e) {
      log('ShellExecute hata: $e');
    }

    // Yontem 3: Process.start
    log('Yontem 3: Process.start deneniyor...');
    try {
      final p = await Process.start(exePath, [], workingDirectory: installDir, mode: ProcessStartMode.detached);
      log('Process.start PID: ${p.pid}');
    } catch (e) {
      log('Process.start hata: $e');
    }
  } else {
    log('discord_clone.exe BULUNAMADI: $exePath');
  }

  log('Updater cikiyor...');
  await Future.delayed(Duration(seconds: 2));
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
  final parts = clean.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  while (parts.length < 3) parts.add(0);
  parts.add(bn);
  return parts;
}
