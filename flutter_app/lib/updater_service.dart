/// Otomatik güncelleme servisi — GitHub Releases tabanlı.
///
/// Akış:
///   1. App `GET https://api.github.com/repos/{owner}/{repo}/releases/latest`
///   2. Yanıttaki `tag_name` (v1.0.1 / 1.0.1) semver ile parse edilir, mevcut
///      sürümden büyükse update gerek
///   3. Assets'tan .zip dosyası bulunur, `browser_download_url`'sinden indirilir
///   4. `%TEMP%\discord_clone_update\` altına yazılır
///   5. PowerShell script üretilir: app kapanmasını bekle → zip extract → kopyala
///      → restart
///   6. PowerShell detached çalışır, app exit(0) yapar
///
/// GitHub Releases avantajı: backend reachability sorun değil, CDN her zaman
/// erişilebilir. Arkadaşlar Cloudflare tunnel'a bağlanamasa bile update'i çekebilir.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'config.dart';

class UpdateRelease {
  final String tagName; // "v1.0.1" veya "1.0.1"
  final String name;
  final String body; // release notes (markdown)
  final List<UpdateAsset> assets;
  final bool draft;
  final bool prerelease;
  final String? publishedAt;

  UpdateRelease({
    required this.tagName,
    required this.name,
    required this.body,
    required this.assets,
    this.draft = false,
    this.prerelease = false,
    this.publishedAt,
  });

  /// `tag_name`'in başındaki 'v' karakterini ayıklanmış semver string.
  String get cleanVersion {
    final t = tagName.trim();
    if (t.toLowerCase().startsWith('v')) return t.substring(1);
    return t;
  }

  /// .zip uzantılı ilk asset.
  UpdateAsset? get zipAsset {
    for (final a in assets) {
      if (a.name.toLowerCase().endsWith('.zip')) return a;
    }
    return null;
  }

  factory UpdateRelease.fromJson(Map<String, dynamic> j) => UpdateRelease(
        tagName: (j['tag_name'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        body: (j['body'] ?? '') as String,
        assets: ((j['assets'] as List?) ?? const [])
            .map((a) => UpdateAsset.fromJson(a as Map<String, dynamic>))
            .toList(),
        draft: (j['draft'] as bool?) ?? false,
        prerelease: (j['prerelease'] as bool?) ?? false,
        publishedAt: j['published_at'] as String?,
      );
}

class UpdateAsset {
  final String name;
  final String downloadUrl;
  final int size;
  UpdateAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });
  factory UpdateAsset.fromJson(Map<String, dynamic> j) => UpdateAsset(
        name: (j['name'] ?? '') as String,
        downloadUrl: (j['browser_download_url'] ?? '') as String,
        size: (j['size'] as num?)?.toInt() ?? 0,
      );
}

class UpdateCheckResult {
  final String currentVersion;
  final String latestVersion;
  final bool hasUpdate;
  final UpdateRelease release;
  UpdateCheckResult({
    required this.currentVersion,
    required this.latestVersion,
    required this.hasUpdate,
    required this.release,
  });
}

class UpdaterService {
  static final UpdaterService instance = UpdaterService._();
  UpdaterService._();

  String? _cachedCurrentVersion;
  bool _downloading = false;
  double _progress = 0;
  String? _statusMessage;

  bool get downloading => _downloading;
  double get progress => _progress;
  String? get statusMessage => _statusMessage;

  /// GitHub Releases API'ye GET. Hata olursa exception fırlatır.
  Future<UpdateCheckResult> checkForUpdate() async {
    final res = await http
        .get(
          Uri.parse(Config.githubLatestReleaseUrl),
          headers: {
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
          },
        )
        .timeout(const Duration(seconds: 8));
    if (res.statusCode == 404) {
      // Henüz release yok — güncel kabul et
      return UpdateCheckResult(
        currentVersion: await _currentVersion(),
        latestVersion: await _currentVersion(),
        hasUpdate: false,
        release: UpdateRelease(tagName: '', name: '', body: '', assets: []),
      );
    }
    if (res.statusCode != 200) {
      throw Exception('GitHub API hatası: HTTP ${res.statusCode}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final release = UpdateRelease.fromJson(data);
    final current = await _currentVersion();
    final hasUpdate = !release.draft &&
        release.tagName.isNotEmpty &&
        release.zipAsset != null &&
        _isNewer(release.cleanVersion, current);
    return UpdateCheckResult(
      currentVersion: current,
      latestVersion: release.cleanVersion,
      hasUpdate: hasUpdate,
      release: release,
    );
  }

  Future<String> _currentVersion() async {
    if (_cachedCurrentVersion != null) return _cachedCurrentVersion!;
    final info = await PackageInfo.fromPlatform();
    _cachedCurrentVersion = info.version;
    return info.version;
  }

  /// Semver karşılaştırma. Hatalı parse'ta false döner.
  bool _isNewer(String latest, String current) {
    try {
      final l = _parse(latest);
      final c = _parse(current);
      for (int i = 0; i < 3; i++) {
        if (l[i] > c[i]) return true;
        if (l[i] < c[i]) return false;
      }
      return false;
    } catch (e) {
      debugPrint('[UPDATER] version parse error: $e');
      return false;
    }
  }

  List<int> _parse(String version) {
    final clean = version.split('+').first.split('-').first;
    final parts = clean.split('.').map(int.parse).toList();
    while (parts.length < 3) {
      parts.add(0);
    }
    return parts.sublist(0, 3);
  }

  /// Release zip'ini indirip PowerShell update script'i ile uygula.
  Future<void> downloadAndApply(UpdateRelease release,
      {void Function(double progress)? onProgress}) async {
    if (_downloading) return;
    final asset = release.zipAsset;
    if (asset == null) {
      throw StateError('Release\'de .zip asset yok');
    }
    _downloading = true;
    _progress = 0;
    _statusMessage = 'İndiriliyor...';

    try {
      final tempDir = Directory.systemTemp;
      final sep = Platform.pathSeparator;
      final stagingDir = Directory('${tempDir.path}${sep}discord_clone_update');
      if (stagingDir.existsSync()) {
        stagingDir.deleteSync(recursive: true);
      }
      stagingDir.createSync(recursive: true);
      final zipPath = '${stagingDir.path}$sep${asset.name}';

      // GitHub asset download — yönlendirme olabilir, http paketi takip eder
      final req = http.Request('GET', Uri.parse(asset.downloadUrl));
      req.followRedirects = true;
      final res = await req.send().timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) {
        throw Exception(
            'İndirme başarısız: HTTP ${res.statusCode} (${asset.downloadUrl})');
      }
      final total = res.contentLength ?? asset.size;
      final sink = File(zipPath).openWrite();
      int received = 0;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          _progress = received / total;
          onProgress?.call(_progress);
        }
      }
      await sink.close();
      _statusMessage = 'Güncelleme uygulanıyor...';

      // PowerShell update script
      final installDir = File(Platform.resolvedExecutable).parent.path;
      final scriptPath = '${stagingDir.path}${sep}apply_update.ps1';
      final logPath = '${stagingDir.path}${sep}update.log';
      final exeName =
          File(Platform.resolvedExecutable).uri.pathSegments.last;
      final script = _buildPowerShellScript(
        zipPath: zipPath,
        installDir: installDir,
        exeName: exeName,
        logPath: logPath,
      );
      await File(scriptPath).writeAsString(script);

      await Process.start(
        'powershell',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          scriptPath,
        ],
        mode: ProcessStartMode.detached,
      );

      await Future.delayed(const Duration(milliseconds: 500));
      exit(0);
    } catch (e) {
      _downloading = false;
      _statusMessage = 'Hata: $e';
      rethrow;
    }
  }

  String _buildPowerShellScript({
    required String zipPath,
    required String installDir,
    required String exeName,
    required String logPath,
  }) {
    return '''
\$ErrorActionPreference = "Continue"
\$logPath = "$logPath"
function Log(\$msg) {
  Add-Content -Path \$logPath -Value "[\$([DateTime]::Now.ToString('HH:mm:ss'))] \$msg" -ErrorAction SilentlyContinue
}

Log "Update başladı: $exeName"

# 1) App'in kapanmasını bekle
\$timeout = 30
while (\$timeout -gt 0) {
  \$proc = Get-Process -Name "${_processBaseName(exeName)}" -ErrorAction SilentlyContinue
  if (-not \$proc) { break }
  Start-Sleep -Milliseconds 500
  \$timeout -= 1
}
Get-Process -Name "${_processBaseName(exeName)}" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Log "App kapandı"

# 2) Zip'i install dir'a extract
Log "Extract: $zipPath -> $installDir"
try {
  Expand-Archive -Path "$zipPath" -DestinationPath "$installDir" -Force
  Log "Extract OK"
} catch {
  Log "Extract HATA: \$_"
  exit 1
}

# 3) App'i yeniden başlat
Start-Sleep -Milliseconds 500
Log "App yeniden başlatılıyor"
Start-Process -FilePath "$installDir\\$exeName"
Log "Bitti"
''';
  }

  String _processBaseName(String exeName) {
    if (exeName.toLowerCase().endsWith('.exe')) {
      return exeName.substring(0, exeName.length - 4);
    }
    return exeName;
  }
}
