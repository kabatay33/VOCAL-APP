import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'config.dart';

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

class AuthResult {
  final String token;
  final int userId;
  final String username;
  final String? email;
  final String? avatarUrl;
  /// Hamachi/Radmin tarzı sanal IP (örn. 26.X.Y.Z). Sunucu register/login'de atar.
  final String? virtualIp;
  AuthResult({
    required this.token,
    required this.userId,
    required this.username,
    this.email,
    this.avatarUrl,
    this.virtualIp,
  });

  AuthResult copyWith({
    String? username,
    String? email,
    Object? avatarUrl = _noChange,
    String? virtualIp,
  }) =>
      AuthResult(
        token: token,
        userId: userId,
        username: username ?? this.username,
        email: email ?? this.email,
        avatarUrl: avatarUrl == _noChange
            ? this.avatarUrl
            : avatarUrl as String?,
        virtualIp: virtualIp ?? this.virtualIp,
      );

  static const _noChange = Object();
}

class UserProfile {
  final int id;
  final String username;
  final String? email;
  final String? avatarUrl;
  /// Hamachi/Radmin tarzı sanal IP (kozmetik).
  final String? virtualIp;
  /// Server üyeleri listesinden geldiğinde rol (owner/member); diğer
  /// yerlerden geldiğinde null.
  final String? role;
  /// Server üyeleri listesinde atanmış custom rol id'leri
  final List<int> roleIds;
  /// Hesaplanan toplam permission bit'leri (owner ise tümü)
  final int permissions;
  UserProfile({
    required this.id,
    required this.username,
    this.email,
    this.avatarUrl,
    this.virtualIp,
    this.role,
    this.roleIds = const [],
    this.permissions = 0,
  });
  factory UserProfile.fromJson(Map<String, dynamic> j) => UserProfile(
        id: j['id'] as int,
        username: j['username'] as String,
        email: j['email'] as String?,
        avatarUrl: j['avatar_url'] as String?,
        virtualIp: j['virtual_ip'] as String?,
        role: j['role'] as String?,
        roleIds: (j['role_ids'] as List?)?.cast<int>() ?? const [],
        permissions: (j['permissions'] as num?)?.toInt() ?? 0,
      );
  bool get isOwner => role == 'owner';
  bool hasPermission(int perm) => isOwner || (permissions & perm) == perm;
}

class Channel {
  final int id;
  final int? serverId;
  final String name;
  final String type;
  Channel({
    required this.id,
    this.serverId,
    required this.name,
    required this.type,
  });
  factory Channel.fromJson(Map<String, dynamic> j) => Channel(
        id: j['id'] as int,
        serverId: (j['server_id'] as int?) ?? (j['serverId'] as int?),
        name: j['name'] as String,
        type: (j['type'] as String?) ?? 'text',
      );
  bool get isVoice => type == 'voice';
}

class ServerInfo {
  final int id;
  final String name;
  final int ownerUserId;
  final String inviteCode;
  final int createdAt;
  final String myRole; // owner / member
  final int myPermissions; // bit flags
  ServerInfo({
    required this.id,
    required this.name,
    required this.ownerUserId,
    required this.inviteCode,
    required this.createdAt,
    required this.myRole,
    required this.myPermissions,
  });
  factory ServerInfo.fromJson(Map<String, dynamic> j) => ServerInfo(
        id: j['id'] as int,
        name: j['name'] as String,
        ownerUserId: j['owner_user_id'] as int,
        inviteCode: j['invite_code'] as String,
        createdAt: (j['created_at'] as num?)?.toInt() ?? 0,
        myRole: (j['my_role'] as String?) ?? 'member',
        myPermissions: (j['my_permissions'] as num?)?.toInt() ?? 0,
      );
  bool get isOwner => myRole == 'owner';
  bool hasPermission(int perm) => isOwner || (myPermissions & perm) == perm;
}

/// Bit flags — backend `src/permissions.js` ile aynı olmalı.
class Permissions {
  static const int manageServer = 1 << 0;
  static const int manageRoles = 1 << 1;
  static const int manageChannels = 1 << 2;
  static const int manageMessages = 1 << 3;
  static const int kickMembers = 1 << 4;
  static const int viewChannels = 1 << 5;
  static const int sendMessages = 1 << 6;
  static const int connectVoice = 1 << 7;
  static const int speakVoice = 1 << 8;
  static const int screenShare = 1 << 9;
  static const int mentionEveryone = 1 << 10;

  /// İnsan dostu isimler (UI'da göstermek için)
  static const Map<int, String> labels = {
    manageServer: 'Sunucuyu Yönet',
    manageRoles: 'Rolleri Yönet',
    manageChannels: 'Kanalları Yönet',
    manageMessages: 'Mesajları Yönet (sil)',
    kickMembers: 'Üye At',
    viewChannels: 'Kanalları Görüntüle',
    sendMessages: 'Mesaj Gönder',
    connectVoice: 'Sese Bağlan',
    speakVoice: 'Konuş (Mikrofon)',
    screenShare: 'Ekran Paylaş',
    mentionEveryone: '@everyone Etiketle',
  };

  /// Kategoriler (UI'da grup gösterimi için)
  static const List<(String, List<int>)> categories = [
    ('Sunucu Yönetimi', [manageServer, manageRoles, manageChannels, kickMembers]),
    ('Kanal Yetkileri', [viewChannels, sendMessages, manageMessages]),
    ('Ses Yetkileri', [connectVoice, speakVoice, screenShare]),
    ('Diğer', [mentionEveryone]),
  ];

  static List<int> get all => labels.keys.toList();
}

class Role {
  final int id;
  final int serverId;
  final String name;
  final String color; // #RRGGBB
  final int permissions;
  final int position;
  final bool isDefault; // @everyone mu
  Role({
    required this.id,
    required this.serverId,
    required this.name,
    required this.color,
    required this.permissions,
    required this.position,
    required this.isDefault,
  });
  factory Role.fromJson(Map<String, dynamic> j) => Role(
        id: j['id'] as int,
        serverId: j['server_id'] as int,
        name: j['name'] as String,
        color: (j['color'] as String?) ?? '#99AAB5',
        permissions: (j['permissions'] as num?)?.toInt() ?? 0,
        position: (j['position'] as num?)?.toInt() ?? 0,
        isDefault: ((j['is_default'] as num?)?.toInt() ?? 0) == 1,
      );

  bool has(int perm) => (permissions & perm) == perm;
}

class Message {
  final int id;
  final int channelId;
  final int userId;
  final String username;
  final String content;
  final int createdAt;
  final String? avatarUrl;
  Message({
    required this.id,
    required this.channelId,
    required this.userId,
    required this.username,
    required this.content,
    required this.createdAt,
    this.avatarUrl,
  });
  factory Message.fromJson(Map<String, dynamic> j) => Message(
        id: j['id'] as int,
        channelId: (j['channel_id'] ?? j['channelId']) as int,
        userId: (j['user_id'] ?? j['userId']) as int,
        username: j['username'] as String,
        content: j['content'] as String,
        createdAt: (j['created_at'] ?? j['createdAt']) as int,
        avatarUrl: j['avatar_url'] as String?,
      );

  Message copyWith({String? username, Object? avatarUrl = _noChange}) =>
      Message(
        id: id,
        channelId: channelId,
        userId: userId,
        username: username ?? this.username,
        content: content,
        createdAt: createdAt,
        avatarUrl:
            avatarUrl == _noChange ? this.avatarUrl : avatarUrl as String?,
      );

  static const _noChange = Object();
}

/// Sunucu ping testi sonucu.
class PingResult {
  final bool ok;
  final int? rttMs;
  final String? serverName;
  final String? error;
  PingResult({required this.ok, this.rttMs, this.serverName, this.error});
}

class Api {
  /// Verilen host'a /api/health çağrısı yapar. Login öncesi sunucu
  /// erişilebilirlik testi için. Config.host'u değiştirmez.
  static Future<PingResult> pingServer(
    String host, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    // host 'http://' veya 'https://' ile başlıyorsa direkt kullan (Cloudflare
    // tunnel URL'leri vs.); değilse default port 3000 ekle (IP/Radmin)
    String url;
    if (host.startsWith('http://') || host.startsWith('https://')) {
      final clean = host.endsWith('/')
          ? host.substring(0, host.length - 1)
          : host;
      url = '$clean/api/health';
    } else {
      url = 'http://$host:3000/api/health';
    }
    final stopwatch = Stopwatch()..start();
    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(timeout);
      stopwatch.stop();
      if (res.statusCode != 200) {
        return PingResult(
          ok: false,
          error: 'HTTP ${res.statusCode}',
          rttMs: stopwatch.elapsedMilliseconds,
        );
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      return PingResult(
        ok: data['ok'] == true,
        rttMs: stopwatch.elapsedMilliseconds,
        serverName: data['name']?.toString(),
      );
    } catch (e) {
      stopwatch.stop();
      return PingResult(ok: false, error: e.toString());
    }
  }

  static Future<AuthResult> register(
    String email,
    String username,
    String password,
  ) async {
    final res = await http.post(
      Uri.parse('${Config.httpBase}/api/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email,
        'username': username,
        'password': password,
      }),
    );
    return _parseAuthResponse(res);
  }

  static Future<AuthResult> login(String email, String password) async {
    final res = await http.post(
      Uri.parse('${Config.httpBase}/api/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );
    return _parseAuthResponse(res);
  }

  static AuthResult _parseAuthResponse(http.Response res) {
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw ApiException(data['error']?.toString() ?? 'Sunucu hatası');
    }
    return AuthResult(
      token: data['token'] as String,
      userId: data['user']['id'] as int,
      username: data['user']['username'] as String,
      email: data['user']['email'] as String?,
      avatarUrl: data['user']['avatar_url'] as String?,
      virtualIp: data['user']['virtual_ip'] as String?,
    );
  }

  /// Avatar dosyasını yükler ve güncellenmiş profili döner.
  static Future<UserProfile> uploadAvatar(
    String token, {
    required List<int> bytes,
    required String filename,
  }) async {
    final uri = Uri.parse('${Config.httpBase}/api/me/avatar');
    final req = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $token'
      ..files.add(http.MultipartFile.fromBytes(
        'avatar',
        bytes,
        filename: filename,
        contentType: _mimeFromFilename(filename),
      ));
    final streamed = await req.send();
    final body = await streamed.stream.bytesToString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    if (streamed.statusCode != 200) {
      throw ApiException(
          data['error']?.toString() ?? 'Avatar yüklenemedi');
    }
    return UserProfile.fromJson(data);
  }

  static MediaType _mimeFromFilename(String filename) {
    final ext = filename.toLowerCase().split('.').last;
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return MediaType('image', 'jpeg');
      case 'png':
        return MediaType('image', 'png');
      case 'webp':
        return MediaType('image', 'webp');
      case 'gif':
        return MediaType('image', 'gif');
      case 'bmp':
        return MediaType('image', 'bmp');
      default:
        return MediaType('application', 'octet-stream');
    }
  }

  static Future<UserProfile> removeAvatar(String token) async {
    final res = await http.delete(
      Uri.parse('${Config.httpBase}/api/me/avatar'),
      headers: {'Authorization': 'Bearer $token'},
    );
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw ApiException(data['error']?.toString() ?? 'Avatar silinemedi');
    }
    return UserProfile.fromJson(data);
  }

  static Future<List<UserProfile>> getUsers(String token) async {
    final res = await http.get(
      Uri.parse('${Config.httpBase}/api/users'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode != 200) {
      throw ApiException('Kullanıcı listesi alınamadı');
    }
    final list = jsonDecode(res.body) as List;
    return list
        .map((e) => UserProfile.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // -------- SERVER --------

  static Future<List<ServerInfo>> getServers(String token) async {
    final res = await http.get(
      Uri.parse('${Config.httpBase}/api/servers'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode != 200) {
      throw ApiException('Sunucu listesi alınamadı');
    }
    final list = jsonDecode(res.body) as List;
    return list
        .map((e) => ServerInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<ServerInfo> createServer(String token, String name) async {
    final res = await http.post(
      Uri.parse('${Config.httpBase}/api/servers'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'name': name}),
    );
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw ApiException(data['error']?.toString() ?? 'Sunucu oluşturulamadı');
    }
    return ServerInfo.fromJson(data);
  }

  static Future<ServerInfo> joinServer(String token, String inviteCode) async {
    final res = await http.post(
      Uri.parse('${Config.httpBase}/api/servers/join'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'invite_code': inviteCode}),
    );
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw ApiException(data['error']?.toString() ?? 'Davet kabul edilemedi');
    }
    return ServerInfo.fromJson(data);
  }

  /// Sunucu sahibi başka bir üyenin rolünü değiştirebilir (admin / member).
  static Future<void> updateMemberRole(
    String token, {
    required int serverId,
    required int userId,
    required String role,
  }) async {
    final res = await http.patch(
      Uri.parse(
          '${Config.httpBase}/api/servers/$serverId/members/$userId/role'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'role': role}),
    );
    if (res.statusCode != 200) {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      throw ApiException(data['error']?.toString() ?? 'Rol değiştirilemedi');
    }
  }

  static Future<void> leaveServer(String token, int serverId) async {
    final res = await http.delete(
      Uri.parse('${Config.httpBase}/api/servers/$serverId/members/me'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode != 200) {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      throw ApiException(data['error']?.toString() ?? 'Ayrılamadı');
    }
  }

  // -------- ROLES --------

  static Future<List<Role>> getServerRoles(
      String token, int serverId) async {
    final res = await http.get(
      Uri.parse('${Config.httpBase}/api/servers/$serverId/roles'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode != 200) {
      throw ApiException('Roller alınamadı');
    }
    final list = jsonDecode(res.body) as List;
    return list.map((e) => Role.fromJson(e as Map<String, dynamic>)).toList();
  }

  static Future<Role> createRole(
    String token,
    int serverId, {
    required String name,
    required String color,
    required int permissions,
  }) async {
    final res = await http.post(
      Uri.parse('${Config.httpBase}/api/servers/$serverId/roles'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'name': name,
        'color': color,
        'permissions': permissions,
      }),
    );
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw ApiException(data['error']?.toString() ?? 'Rol oluşturulamadı');
    }
    return Role.fromJson(data);
  }

  static Future<void> updateRole(
    String token,
    int roleId, {
    String? name,
    String? color,
    int? permissions,
  }) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (color != null) body['color'] = color;
    if (permissions != null) body['permissions'] = permissions;
    final res = await http.patch(
      Uri.parse('${Config.httpBase}/api/roles/$roleId'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode(body),
    );
    if (res.statusCode != 200) {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      throw ApiException(data['error']?.toString() ?? 'Rol güncellenemedi');
    }
  }

  static Future<void> deleteRole(String token, int roleId) async {
    final res = await http.delete(
      Uri.parse('${Config.httpBase}/api/roles/$roleId'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode != 200) {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      throw ApiException(data['error']?.toString() ?? 'Rol silinemedi');
    }
  }

  static Future<void> assignRole(
    String token, {
    required int serverId,
    required int userId,
    required int roleId,
  }) async {
    final res = await http.post(
      Uri.parse(
          '${Config.httpBase}/api/servers/$serverId/members/$userId/roles/$roleId'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode != 200) {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      throw ApiException(data['error']?.toString() ?? 'Rol atanamadı');
    }
  }

  static Future<void> unassignRole(
    String token, {
    required int serverId,
    required int userId,
    required int roleId,
  }) async {
    final res = await http.delete(
      Uri.parse(
          '${Config.httpBase}/api/servers/$serverId/members/$userId/roles/$roleId'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode != 200) {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      throw ApiException(data['error']?.toString() ?? 'Rol kaldırılamadı');
    }
  }

  // -------- CHANNELS --------

  static Future<List<Channel>> getServerChannels(
      String token, int serverId) async {
    final res = await http.get(
      Uri.parse('${Config.httpBase}/api/servers/$serverId/channels'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode != 200) {
      throw ApiException('Kanallar alınamadı');
    }
    final list = jsonDecode(res.body) as List;
    return list.map((e) => Channel.fromJson(e as Map<String, dynamic>)).toList();
  }

  static Future<List<UserProfile>> getServerMembers(
      String token, int serverId) async {
    final res = await http.get(
      Uri.parse('${Config.httpBase}/api/servers/$serverId/members'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode != 200) {
      throw ApiException('Üyeler alınamadı');
    }
    final list = jsonDecode(res.body) as List;
    return list
        .map((e) => UserProfile.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<UserProfile> getMe(String token) async {
    final res = await http.get(
      Uri.parse('${Config.httpBase}/api/me'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode != 200) {
      throw ApiException('Profil alınamadı');
    }
    return UserProfile.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  static Future<UserProfile> updateProfile(
    String token, {
    String? username,
    String? email,
    String? password,
    String? currentPassword,
  }) async {
    final body = <String, dynamic>{};
    if (username != null) body['username'] = username;
    if (email != null) body['email'] = email;
    if (password != null && password.isNotEmpty) {
      body['password'] = password;
      body['currentPassword'] = currentPassword;
    }
    final res = await http.patch(
      Uri.parse('${Config.httpBase}/api/me'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode(body),
    );
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw ApiException(data['error']?.toString() ?? 'Güncellenemedi');
    }
    return UserProfile.fromJson(data);
  }

  static Future<Channel> createChannel(
      String token, int serverId, String name, String type) async {
    final res = await http.post(
      Uri.parse('${Config.httpBase}/api/servers/$serverId/channels'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'name': name, 'type': type}),
    );
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw ApiException(data['error']?.toString() ?? 'Kanal oluşturulamadı');
    }
    return Channel.fromJson(data);
  }

  static Future<void> renameChannel(String token, int id, String name) async {
    final res = await http.patch(
      Uri.parse('${Config.httpBase}/api/channels/$id'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'name': name}),
    );
    if (res.statusCode != 200) {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      throw ApiException(data['error']?.toString() ?? 'Kanal güncellenemedi');
    }
  }

  static Future<void> deleteChannel(String token, int id) async {
    final res = await http.delete(
      Uri.parse('${Config.httpBase}/api/channels/$id'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode != 200) {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      throw ApiException(data['error']?.toString() ?? 'Kanal silinemedi');
    }
  }

  static Future<void> deleteMessage(String token, int messageId) async {
    final res = await http.delete(
      Uri.parse('${Config.httpBase}/api/messages/$messageId'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode != 200) {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      throw ApiException(data['error']?.toString() ?? 'Mesaj silinemedi');
    }
  }

  static Future<List<Message>> getChannelMessages(
      String token, int channelId) async {
    final res = await http.get(
      Uri.parse('${Config.httpBase}/api/channels/$channelId/messages'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode != 200) {
      throw ApiException('Mesajlar alınamadı');
    }
    final list = jsonDecode(res.body) as List;
    return list.map((e) => Message.fromJson(e as Map<String, dynamic>)).toList();
  }

  static Future<List<Message>> getMessages(int channelId) async {
    final res = await http.get(
      Uri.parse('${Config.httpBase}/api/channels/$channelId/messages'),
    );
    if (res.statusCode != 200) {
      throw ApiException('Mesajlar alınamadı');
    }
    final list = jsonDecode(res.body) as List;
    return list.map((e) => Message.fromJson(e as Map<String, dynamic>)).toList();
  }
}
