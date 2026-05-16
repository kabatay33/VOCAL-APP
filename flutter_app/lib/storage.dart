import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Kullanıcının kaydettiği sunucu (nickname + IP).
class SavedServer {
  final String nickname;
  final String host;
  final int lastUsedAt; // millisecondsSinceEpoch
  SavedServer({
    required this.nickname,
    required this.host,
    required this.lastUsedAt,
  });

  Map<String, dynamic> toJson() => {
        'nickname': nickname,
        'host': host,
        'lastUsedAt': lastUsedAt,
      };

  factory SavedServer.fromJson(Map<String, dynamic> j) => SavedServer(
        nickname: j['nickname'] as String? ?? '',
        host: j['host'] as String? ?? '',
        lastUsedAt: (j['lastUsedAt'] as num?)?.toInt() ?? 0,
      );

  SavedServer copyWith({String? nickname, String? host, int? lastUsedAt}) =>
      SavedServer(
        nickname: nickname ?? this.nickname,
        host: host ?? this.host,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      );
}

class Storage {
  static const _kToken = 'token';
  static const _kUsername = 'username';
  static const _kUserId = 'userId';
  static const _kServerHost = 'serverHost';
  static const _kMembersPanelVisible = 'membersPanelVisible';
  static const _kRememberMe = 'remember_me';
  static const _kSavedServers = 'saved_servers_v1';
  // Son giriş yapılan kullanıcı adı — login öncesi UI'da gösterilir.
  static const _kLastUsername = 'last_username';

  static Future<String?> getServerHost() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kServerHost);
  }

  static Future<void> setServerHost(String host) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kServerHost, host);
  }

  static Future<bool> getMembersPanelVisible() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kMembersPanelVisible) ?? true;
  }

  static Future<void> setMembersPanelVisible(bool visible) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kMembersPanelVisible, visible);
  }

  static const _kActiveServerId = 'active_server_id_int';

  static Future<int?> getActiveServerId() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_kActiveServerId);
  }

  static Future<void> setActiveServerId(int serverId) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kActiveServerId, serverId);
  }

  static const _kAudioInputId = 'audio_input_id';
  static const _kAudioOutputId = 'audio_output_id';
  static const _kCameraDeviceId = 'camera_device_id';
  static const _kCameraWidth = 'camera_width';
  static const _kCameraFps = 'camera_fps';

  static Future<String?> getAudioInputId() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kAudioInputId);
  }

  static Future<void> setAudioInputId(String? deviceId) async {
    final p = await SharedPreferences.getInstance();
    if (deviceId == null) {
      await p.remove(_kAudioInputId);
    } else {
      await p.setString(_kAudioInputId, deviceId);
    }
  }

  static Future<String?> getAudioOutputId() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kAudioOutputId);
  }

  static Future<void> setAudioOutputId(String? deviceId) async {
    final p = await SharedPreferences.getInstance();
    if (deviceId == null) {
      await p.remove(_kAudioOutputId);
    } else {
      await p.setString(_kAudioOutputId, deviceId);
    }
  }

  static Future<String?> getCameraDeviceId() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kCameraDeviceId);
  }

  static Future<void> setCameraDeviceId(String? deviceId) async {
    final p = await SharedPreferences.getInstance();
    if (deviceId == null) {
      await p.remove(_kCameraDeviceId);
    } else {
      await p.setString(_kCameraDeviceId, deviceId);
    }
  }

  static Future<int> getCameraWidth() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_kCameraWidth) ?? 1280;
  }

  static Future<void> setCameraWidth(int width) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kCameraWidth, width);
  }

  static Future<int> getCameraFps() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_kCameraFps) ?? 30;
  }

  static Future<void> setCameraFps(int fps) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kCameraFps, fps);
  }

  static Future<void> save({
    required String token,
    required String username,
    required int userId,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kToken, token);
    await p.setString(_kUsername, username);
    await p.setInt(_kUserId, userId);
  }

  static Future<({String token, String username, int userId})?> load() async {
    final p = await SharedPreferences.getInstance();
    final t = p.getString(_kToken);
    final u = p.getString(_kUsername);
    final id = p.getInt(_kUserId);
    if (t == null || u == null || id == null) return null;
    return (token: t, username: u, userId: id);
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kToken);
    await p.remove(_kUsername);
    await p.remove(_kUserId);
  }

  static Future<bool> getRememberMe() async {
    final p = await SharedPreferences.getInstance();
    // İlk açılışta varsayılan: açık (kullanıcı genelde bunu istiyor)
    return p.getBool(_kRememberMe) ?? true;
  }

  static Future<void> setRememberMe(bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kRememberMe, value);
  }

  static Future<String?> getLastUsername() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kLastUsername);
  }

  static Future<void> setLastUsername(String? username) async {
    final p = await SharedPreferences.getInstance();
    if (username == null) {
      await p.remove(_kLastUsername);
    } else {
      await p.setString(_kLastUsername, username);
    }
  }

  /// Kayıtlı sunucu listesi. lastUsedAt'a göre azalan sırada döner.
  static Future<List<SavedServer>> getSavedServers() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kSavedServers);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      final servers = list
          .map((e) => SavedServer.fromJson(e as Map<String, dynamic>))
          .toList();
      servers.sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
      return servers;
    } catch (_) {
      return [];
    }
  }

  static Future<void> setSavedServers(List<SavedServer> servers) async {
    final p = await SharedPreferences.getInstance();
    final raw = jsonEncode(servers.map((s) => s.toJson()).toList());
    await p.setString(_kSavedServers, raw);
  }

  /// Ekler veya host eşleşiyorsa nickname ve lastUsedAt'i günceller.
  static Future<void> upsertServer(SavedServer server) async {
    final list = await getSavedServers();
    final idx = list.indexWhere((s) => s.host == server.host);
    if (idx >= 0) {
      list[idx] = list[idx].copyWith(
        nickname: server.nickname,
        lastUsedAt: server.lastUsedAt,
      );
    } else {
      list.add(server);
    }
    await setSavedServers(list);
  }

  /// Sunucuya bağlandığında lastUsedAt'i günceller (varsa).
  static Future<void> touchServer(String host) async {
    final list = await getSavedServers();
    final idx = list.indexWhere((s) => s.host == host);
    if (idx >= 0) {
      list[idx] = list[idx]
          .copyWith(lastUsedAt: DateTime.now().millisecondsSinceEpoch);
      await setSavedServers(list);
    }
  }

  static Future<void> removeServer(String host) async {
    final list = await getSavedServers();
    list.removeWhere((s) => s.host == host);
    await setSavedServers(list);
  }
}
