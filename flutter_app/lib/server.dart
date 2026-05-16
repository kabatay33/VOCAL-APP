import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

class Server {
  final String id;
  final String name;
  final String host;
  const Server({required this.id, required this.name, required this.host});

  Server copyWith({String? name, String? host}) =>
      Server(id: id, name: name ?? this.name, host: host ?? this.host);

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'host': host};
  factory Server.fromJson(Map<String, dynamic> j) => Server(
        id: j['id'] as String,
        name: j['name'] as String,
        host: j['host'] as String,
      );

  static String generateId() {
    final r = Random();
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(12, (_) => chars[r.nextInt(chars.length)]).join();
  }
}

/// Sunucu listesini ve aktif sunucuyu yöneten yardımcı sınıf.
class ServerStore {
  static const _kServers = 'servers_list';
  static const _kActiveId = 'active_server_id';
  static const String defaultHost = '26.59.206.29';

  /// Kayıtlı sunucuları yükler. Hiç yoksa, varsayılan bir tane oluşturup döner.
  static Future<List<Server>> loadServers() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kServers);
    if (raw == null) {
      // Varsayılan sunucu
      final defaultServer = Server(
        id: Server.generateId(),
        name: 'Sunucum',
        host: defaultHost,
      );
      await saveServers([defaultServer]);
      await setActiveId(defaultServer.id);
      return [defaultServer];
    }
    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => Server.fromJson(e as Map<String, dynamic>))
          .toList();
      if (list.isEmpty) {
        final defaultServer = Server(
          id: Server.generateId(),
          name: 'Sunucum',
          host: defaultHost,
        );
        await saveServers([defaultServer]);
        await setActiveId(defaultServer.id);
        return [defaultServer];
      }
      return list;
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveServers(List<Server> servers) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _kServers,
      jsonEncode(servers.map((s) => s.toJson()).toList()),
    );
  }

  static Future<String?> getActiveId() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kActiveId);
  }

  static Future<void> setActiveId(String id) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kActiveId, id);
  }

  static Future<Server?> getActiveServer() async {
    final servers = await loadServers();
    final id = await getActiveId();
    if (id != null) {
      final found = servers.where((s) => s.id == id).cast<Server?>();
      if (found.isNotEmpty) return found.first;
    }
    return servers.isNotEmpty ? servers.first : null;
  }
}
