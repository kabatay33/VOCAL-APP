/// VOCAL-APP Updater (saf Dart, dart compile exe ile build edilir).
///
/// Akış:
///   1. Radmin VPN aktif değilse başlatmaya çalış (silent)
///   2. installDir tespit et (updater/ alt klasörü veya yanındaki exe)
///   3. GitHub Releases /latest çek
///   4. Mevcut version.txt ile karşılaştır
///   5. Yeni sürüm varsa indir + extract + kopyala + version.txt güncelle
///   6. LocalHub.exe başlat (cmd /c start ile detached) + exit
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
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:http/http.dart' as http;

// ==================== CONFIG ====================
const String githubOwner = 'kabatay33';
const String githubRepo = 'LocalHub';
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
  // Log dosyası — updater.exe'nin yanına. Append mode (silmeyiz) ki birden
  // fazla updater run'i debug için ayrı tutalabilsin.
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  _logFile = File('$exeDir${Platform.pathSeparator}updater.log');
  // Sadece log dosyası 5 MB'tan büyükse rotate et
  try {
    if (_logFile.existsSync() && _logFile.lengthSync() > 5 * 1024 * 1024) {
      _logFile.deleteSync();
    }
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

    // Backend zaten çalışıyor mu? (host bilgisayarı için)
    // Update kontrol etmeden ÖNCE backend çalışıyor olsun ki app açıldığında
    // splash uzun beklemesin. Update gelirse zaten kapatıp tekrar açacağız.
    await ensureBackendRunning(installDir);

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

    // 7. App'in ve backend'in kapanmasını bekle + kopyala
    log('LocalHub.exe kapanmasini bekleniyor...');
    await waitForAppExit();
    // Backend de kapat — dosya lock'larını önle (backend\src\server.js
    // dosyası çalışan node tarafından açık olabilir)
    log('Backend kapatiliyor (dosya lock\'lari icin)...');
    await stopBackend();
    log('Kopyalama...');
    copyRecursive(extractDir, installDir);
    writeVersion(installDir, latestVersion);
    log('Kopyalama OK');

    // Yeni backend kodu geldi — yeniden başlat
    await ensureBackendRunning(installDir);

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
    if (File('$parent\\LocalHub.exe').existsSync()) {
      return parent;
    }
  }

  // Senaryo 2: yanında LocalHub.exe var
  if (File('$exeDir\\LocalHub.exe').existsSync()) {
    return exeDir;
  }

  // Senaryo 3: üst klasörde
  final parent = Directory(exeDir).parent.path;
  if (File('$parent\\LocalHub.exe').existsSync()) {
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
    if (!isRunning('LocalHub.exe')) return;
    await Future.delayed(const Duration(seconds: 1));
  }
  log('LocalHub.exe hala calisiyor, zorla kapatiliyor...');
  try {
    await Process.run('taskkill', ['/F', '/IM', 'LocalHub.exe']);
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
  final exePath = '$installDir\\LocalHub.exe';
  log('Baslatiliyor: $exePath');
  if (!File(exePath).existsSync()) {
    log('HATA: LocalHub.exe bulunamadi: $exePath');
    log('Cikiyor (5 sn sonra)...');
    await Future.delayed(const Duration(seconds: 5));
    exit(1);
  }

  // LocalHub'u başlatmadan önce lock file yaz — LocalHub bunu
  // görüp updater'ı yeniden tetiklemesin (endless loop önleme).
  writeSkipUpdaterLock();
  try {
    // Normal Process.start kullan — LocalHub GUI uygulaması, görünür olmalı
    await Process.start(
      exePath,
      const [],
      workingDirectory: installDir,
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
    log('LocalHub.exe baslatildi (lock file ile)');
  } catch (e) {
    log('Spawn hatasi: $e');
  }

  // Updater kendisini exit'leyecek
  await Future.delayed(const Duration(milliseconds: 500));
  exit(0);
}

// ==================== BACKEND ====================
/// installDir altında `backend\src\server.js` var mı? Varsa o path'i döner.
String? findBackendDir(String installDir) {
  final candidate = '$installDir\\backend';
  if (File('$candidate\\src\\server.js').existsSync()) return candidate;
  // Dev mode: proje root altında backend (test ortamında çalışırken)
  final dev1 =
      Directory('$installDir\\..\\..\\..\\..\\..\\..\\backend').absolute.path;
  if (File('$dev1\\src\\server.js').existsSync()) return dev1;
  final dev2 =
      Directory('$installDir\\..\\..\\..\\..\\..\\backend').absolute.path;
  if (File('$dev2\\src\\server.js').existsSync()) return dev2;
  return null;
}

/// node.exe bulunamadıysa null. Önce installDir yanında "node.exe" sonra PATH.
String? findNode(String installDir) {
  // Bundled node.exe
  final bundled = '$installDir\\node.exe';
  if (File(bundled).existsSync()) return bundled;
  // PATH'den ara
  try {
    final r = Process.runSync('where', ['node'],
        runInShell: false, stdoutEncoding: const SystemEncoding());
    if (r.exitCode == 0) {
      final lines = (r.stdout as String).split('\n');
      for (final l in lines) {
        final s = l.trim();
        if (s.toLowerCase().endsWith('node.exe') && File(s).existsSync()) {
          return s;
        }
      }
    }
  } catch (_) {}
  return null;
}

/// Port 3000 dinleniyor mu? Backend zaten çalışıyorsa true.
Future<bool> isPort3000InUse() async {
  try {
    final server = await ServerSocket.bind('127.0.0.1', 3000);
    await server.close();
    return false;
  } catch (_) {
    return true;
  }
}

/// Backend bulup başlat (zaten çalışıyorsa skip).
Future<void> ensureBackendRunning(String installDir) async {
  try {
    if (await isPort3000InUse()) {
      log('Backend zaten port 3000\'de calisiyor');
      return;
    }
    final backendDir = findBackendDir(installDir);
    if (backendDir == null) {
      log('Backend klasoru bulunamadi (installDir\\backend\\src\\server.js yok)');
      return;
    }
    final nodePath = findNode(installDir);
    if (nodePath == null) {
      log('node.exe bulunamadi (PATH\'de yok ve bundled degil)');
      return;
    }
    log('Backend invisible spawn ediliyor: $nodePath $backendDir\\src\\server.js');
    // Win32 CreateProcessW + CREATE_NO_WINDOW — hiç konsol penceresi açılmaz
    final ok = invisibleSpawn(nodePath, ['src\\server.js'], backendDir);
    if (!ok) {
      log('invisibleSpawn basarisiz — fallback cmd start /B');
      await Process.start(
        'cmd',
        [
          '/c',
          'start',
          '""',
          '/B',
          '/D',
          backendDir,
          nodePath,
          'src\\server.js'
        ],
        mode: ProcessStartMode.detached,
        runInShell: false,
      );
    }
    // Port 3000 dinlemeye başlamasını bekle (max 25 sn).
    // node + better-sqlite3 ilk init biraz sürebilir, ayrıca CREATE_NO_WINDOW
    // ile spawn'da pipe inherit'i farklı olduğu için startup biraz daha yavaş.
    for (var i = 0; i < 50; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (await isPort3000InUse()) {
        log('Backend hazir (port 3000)');
        return;
      }
    }
    log('Backend port 3000 dinlemeye baslamadi (25sn timeout) — LocalHub yine de denesin');
  } catch (e) {
    log('Backend baslatma hatasi: $e');
  }
}

/// Çalışan node.exe'leri (port 3000'i tutan) öldür.
Future<void> stopBackend() async {
  if (!await isPort3000InUse()) {
    log('Port 3000 zaten bos — kapatacak backend yok');
    return;
  }
  try {
    // taskkill ile tüm node.exe'leri öldür — basit ama agresif.
    // Daha akıllı yöntem: netstat ile port 3000'i tutan PID'i bul + sadece
    // onu kapat. Ama bizim updater'da basit tutalım.
    await Process.run('taskkill', ['/F', '/IM', 'node.exe'],
        runInShell: false);
    log('node.exe killed');
  } catch (e) {
    log('Backend kapatma hatasi: $e');
  }
  // Port serbest kalmasını bekle
  for (var i = 0; i < 6; i++) {
    await Future.delayed(const Duration(milliseconds: 500));
    if (!await isPort3000InUse()) return;
  }
  log('Backend kapatildi ama port 3000 hala dolu? (devam ediliyor)');
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

// ==================== LOCK FILE ====================
/// LocalHub'un updater'ı yeniden spawn etmesini önlemek için
/// %TEMP%\vocal_app_skip_updater dosyası yazar. LocalHub main()'de
/// bu dosya varsa updater'ı atlar.
void writeSkipUpdaterLock() {
  try {
    final tempPath = Platform.environment['TEMP'] ?? Directory.systemTemp.path;
    // NOT: '$tempPath\\vocal...' Dart'ta `\v` vertical-tab escape oluyor!
    // Platform.pathSeparator kullanmak güvenli.
    final lock = File('$tempPath${Platform.pathSeparator}vocal_app_skip_updater');
    lock.writeAsStringSync(DateTime.now().toIso8601String());
    log('Skip-updater lock yazildi: ${lock.path}');
  } catch (e) {
    log('Lock yazma hatasi: $e');
  }
}

// ==================== INVISIBLE SPAWN ====================
/// Win32 CreateProcessW + CREATE_NO_WINDOW + DETACHED_PROCESS.
/// Hiç konsol penceresi açmaz, parent öldükten sonra da yaşamaya devam eder.
bool invisibleSpawn(String exePath, List<String> args, String workingDir) {
  try {
    const createNoWindow = 0x08000000;
    const detachedProcess = 0x00000008;
    const flags = createNoWindow | detachedProcess;

    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final createProcessW = kernel32.lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Pointer<Utf16>,
          Pointer<Void>,
          Pointer<Void>,
          Int32,
          Uint32,
          Pointer<Void>,
          Pointer<Utf16>,
          Pointer<Uint8>,
          Pointer<Uint8>,
        ),
        int Function(
          Pointer<Utf16>,
          Pointer<Utf16>,
          Pointer<Void>,
          Pointer<Void>,
          int,
          int,
          Pointer<Void>,
          Pointer<Utf16>,
          Pointer<Uint8>,
          Pointer<Uint8>,
        )>('CreateProcessW');
    final closeHandle = kernel32.lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('CloseHandle');

    final si = calloc<Uint8>(104);
    si.cast<Uint32>().value = 104; // STARTUPINFOW.cb
    final pi = calloc<Uint8>(24);

    final cmdBuf = StringBuffer('"$exePath"');
    for (final a in args) {
      cmdBuf.write(' "$a"');
    }
    final cmdLine = cmdBuf.toString().toNativeUtf16();
    final dirPtr = workingDir.toNativeUtf16();

    try {
      final ok = createProcessW(
        nullptr,
        cmdLine,
        nullptr,
        nullptr,
        0,
        flags,
        nullptr,
        dirPtr,
        si,
        pi,
      );
      if (ok == 0) return false;
      final piPtr = pi.cast<IntPtr>();
      final hProcess = piPtr.value;
      final hThread = (piPtr + 1).value;
      closeHandle(Pointer<Void>.fromAddress(hProcess));
      closeHandle(Pointer<Void>.fromAddress(hThread));
      return true;
    } finally {
      malloc.free(cmdLine);
      malloc.free(dirPtr);
      malloc.free(si);
      malloc.free(pi);
    }
  } catch (e) {
    log('invisibleSpawn hata: $e');
    return false;
  }
}
