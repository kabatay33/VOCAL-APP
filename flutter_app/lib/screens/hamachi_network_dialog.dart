import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../api.dart';
import '../storage.dart';
import '../tunnel_service.dart';

/// Sunucu yönetim paneli — kayıtlı sunucu listesi + Cloudflare Tunnel kontrolü.
///
/// - Sol-üst: Cloudflare Public Tunnel paneli (host PC için)
/// - Alt: kayıtlı sunucu listesi (ekle/test et/bağlan/sil)
/// - Tunnel açıldıysa public URL otomatik olarak listeye eklenir
class HamachiNetworkDialog extends StatefulWidget {
  /// Şu an bağlı olan backend host'u (UI'da "aktif" işaretlemek için).
  final String currentHost;
  /// Login yapmışsak kullanıcı adı (UI başlığında gösterilir).
  final String? currentUsername;
  const HamachiNetworkDialog({
    super.key,
    required this.currentHost,
    this.currentUsername,
  });

  @override
  State<HamachiNetworkDialog> createState() => _HamachiNetworkDialogState();
}

class _HamachiNetworkDialogState extends State<HamachiNetworkDialog> {
  List<SavedServer> _servers = [];
  // host -> ping sonucu
  final Map<String, PingResult> _pingResults = {};
  final Set<String> _pinging = {};
  bool _loading = true;

  TunnelService get _tunnel => TunnelService.instance;

  @override
  void initState() {
    super.initState();
    _load();
    _tunnel.addListener(_onTunnelChanged);
  }

  @override
  void dispose() {
    _tunnel.removeListener(_onTunnelChanged);
    super.dispose();
  }

  void _onTunnelChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final list = await Storage.getSavedServers();
    if (mounted) {
      setState(() {
        _servers = list;
        _loading = false;
      });
    }
  }

  Future<void> _addOrEdit({SavedServer? existing}) async {
    final res = await showDialog<SavedServer>(
      context: context,
      builder: (_) => _ServerFormDialog(existing: existing),
    );
    if (res == null) return;
    if (existing != null && existing.host != res.host) {
      await Storage.removeServer(existing.host);
    }
    await Storage.upsertServer(res);
    await _load();
  }

  Future<void> _remove(SavedServer s) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF36393F),
        title: const Text('Sunucuyu Sil',
            style: TextStyle(color: Colors.white)),
        content: Text(
          '"${s.nickname}" (${s.host}) listenden silinsin mi?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('İptal',
                style: TextStyle(color: Colors.white70)),
          ),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await Storage.removeServer(s.host);
    if (mounted) {
      setState(() {
        _pingResults.remove(s.host);
        _servers.removeWhere((x) => x.host == s.host);
      });
    }
  }

  Future<void> _ping(SavedServer s) async {
    if (_pinging.contains(s.host)) return;
    setState(() => _pinging.add(s.host));
    final r = await Api.pingServer(s.host);
    if (!mounted) return;
    setState(() {
      _pinging.remove(s.host);
      _pingResults[s.host] = r;
    });
  }

  Future<void> _pingAll() async {
    for (final s in _servers) {
      _ping(s);
    }
  }

  Future<void> _select(SavedServer s) async {
    Navigator.of(context).pop(s.host);
  }

  Future<void> _toggleTunnel() async {
    try {
      if (_tunnel.running) {
        await _tunnel.stop();
      } else {
        final url = await _tunnel.start();
        if (mounted) {
          await Storage.upsertServer(SavedServer(
            nickname: 'Public Tunnel (bu cihaz)',
            host: url,
            lastUsedAt: DateTime.now().millisecondsSinceEpoch,
          ));
          await _load();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Tunnel hatası: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1E1F22),
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600, maxHeight: 680),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(),
            _tunnelPanel(),
            const Divider(color: Colors.white12, height: 1),
            Expanded(child: _networksList()),
            const Divider(color: Colors.white12, height: 1),
            _bottomActions(),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
      child: Row(
        children: [
          const Icon(Icons.dns, color: Color(0xFF5865F2), size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Sunucular',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    )),
                if (widget.currentUsername != null)
                  Text('Kullanıcı: ${widget.currentUsername}',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.network_check, color: Colors.white70),
            tooltip: 'Hepsini ping at',
            onPressed: _servers.isEmpty ? null : _pingAll,
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white54),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  /// Cloudflare Tunnel paneli — host PC backend'ini public URL'e açar.
  /// Bu cihaz host ise tıklayıp public URL alır, arkadaşlarına gönderir.
  Widget _tunnelPanel() {
    final running = _tunnel.running;
    final starting = _tunnel.starting;
    final url = _tunnel.publicUrl;
    final statusMsg = _tunnel.statusMessage;

    return Container(
      color: const Color(0xFF1F2126),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                running ? Icons.cloud_done : Icons.cloud_outlined,
                color: running ? const Color(0xFFF38020) : Colors.white54,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      running
                          ? 'Public Tunnel AÇIK'
                          : starting
                              ? 'Tunnel başlatılıyor...'
                              : 'Public Tunnel Kapalı',
                      style: TextStyle(
                        color: running
                            ? const Color(0xFFF38020)
                            : Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      running
                          ? 'Cloudflare üzerinden — arkadaşların bu URL ile bağlanır'
                          : 'Bu cihaz host ise tıkla, arkadaşlarına paylaşacağın public URL alırsın',
                      style: const TextStyle(
                          color: Colors.white60, fontSize: 11),
                    ),
                    if (statusMsg != null && !running && !starting) ...[
                      const SizedBox(height: 2),
                      Text(statusMsg,
                          style: const TextStyle(
                              color: Colors.redAccent, fontSize: 11)),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                icon: starting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Icon(
                        running
                            ? Icons.stop_circle
                            : Icons.cloud_upload,
                        size: 16),
                label: Text(running
                    ? 'Kapat'
                    : starting
                        ? 'Bekle...'
                        : 'İnternete Aç'),
                style: FilledButton.styleFrom(
                  backgroundColor: running
                      ? const Color(0xFF4F545C)
                      : const Color(0xFFF38020),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                ),
                onPressed: starting ? null : _toggleTunnel,
              ),
            ],
          ),
          if (url != null) ...[
            const SizedBox(height: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF202225),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                    color: const Color(0xFFF38020).withValues(alpha: 0.5)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.link,
                      size: 14, color: Color(0xFFF38020)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: SelectableText(
                      url,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.content_copy,
                        size: 14, color: Colors.white70),
                    tooltip: 'URL\'i kopyala',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: url));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                              'Public URL kopyalandı — arkadaşlarına gönder'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Bu URL\'i arkadaşına gönder. Onlar "Yeni Sunucu Ekle" → URL alanına yapıştırsın.',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  Widget _networksList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_servers.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined,
                color: Colors.white.withValues(alpha: 0.2), size: 60),
            const SizedBox(height: 12),
            const Text('Henüz kayıtlı sunucu yok',
                style: TextStyle(color: Colors.white54)),
            const SizedBox(height: 4),
            const Text('Aşağıdan yeni bir sunucu ekleyebilirsin.',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: _servers.length,
      separatorBuilder: (_, _) =>
          const Divider(color: Colors.white12, height: 1),
      itemBuilder: (_, i) => _serverTile(_servers[i]),
    );
  }

  Widget _serverTile(SavedServer s) {
    final isActive = s.host == widget.currentHost;
    final ping = _pingResults[s.host];
    final isPinging = _pinging.contains(s.host);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 40,
            decoration: BoxDecoration(
              color: isActive
                  ? const Color(0xFF5865F2)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      s.nickname.isEmpty ? s.host : s.nickname,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (isActive) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: const Color(0xFF5865F2),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: const Text('AKTİF',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5)),
                      ),
                    ],
                  ],
                ),
                Text(s.host,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 12)),
                if (ping != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        Icon(
                          ping.ok
                              ? Icons.check_circle
                              : Icons.error_outline,
                          size: 12,
                          color: ping.ok
                              ? Colors.greenAccent
                              : Colors.redAccent,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            ping.ok
                                ? '${ping.rttMs} ms${ping.serverName != null ? " — ${ping.serverName}" : ""}'
                                : (ping.error ?? 'Bağlanılamadı'),
                            style: TextStyle(
                              color: ping.ok
                                  ? Colors.greenAccent
                                  : Colors.redAccent,
                              fontSize: 11,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          isPinging
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white54),
                )
              : IconButton(
                  icon: const Icon(Icons.network_ping,
                      size: 18, color: Colors.white60),
                  tooltip: 'Test et',
                  onPressed: () => _ping(s),
                ),
          IconButton(
            icon: const Icon(Icons.edit, size: 18, color: Colors.white60),
            tooltip: 'Düzenle',
            onPressed: () => _addOrEdit(existing: s),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline,
                size: 18, color: Colors.redAccent),
            tooltip: 'Sil',
            onPressed: () => _remove(s),
          ),
          const SizedBox(width: 4),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: isActive
                  ? const Color(0xFF4F545C)
                  : const Color(0xFF5865F2),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              minimumSize: const Size(0, 32),
            ),
            onPressed: isActive ? null : () => _select(s),
            child: Text(isActive ? 'Seçili' : 'Bağlan'),
          ),
        ],
      ),
    );
  }

  Widget _bottomActions() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _addOrEdit(),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Yeni Sunucu Ekle'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white24),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerFormDialog extends StatefulWidget {
  final SavedServer? existing;
  const _ServerFormDialog({this.existing});

  @override
  State<_ServerFormDialog> createState() => _ServerFormDialogState();
}

class _ServerFormDialogState extends State<_ServerFormDialog> {
  late final TextEditingController _nickCtrl;
  late final TextEditingController _hostCtrl;
  bool _testing = false;
  PingResult? _testResult;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nickCtrl = TextEditingController(text: widget.existing?.nickname ?? '');
    _hostCtrl = TextEditingController(text: widget.existing?.host ?? '');
  }

  @override
  void dispose() {
    _nickCtrl.dispose();
    _hostCtrl.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    final host = _hostCtrl.text.trim();
    if (host.isEmpty) {
      setState(() => _error = 'IP/URL boş olamaz');
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final r = await Api.pingServer(host);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = r;
    });
  }

  void _save() {
    final nick = _nickCtrl.text.trim();
    final host = _hostCtrl.text.trim();
    if (host.isEmpty) {
      setState(() => _error = 'IP/URL boş olamaz');
      return;
    }
    Navigator.pop(
      context,
      SavedServer(
        nickname: nick,
        host: host,
        lastUsedAt: widget.existing?.lastUsedAt ??
            DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Dialog(
      backgroundColor: const Color(0xFF2F3136),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                isEdit ? 'Sunucuyu Düzenle' : 'Yeni Sunucu',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 14),
              const Text('TAKMA AD (NICKNAME)',
                  style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1)),
              const SizedBox(height: 6),
              TextField(
                controller: _nickCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: _input(
                    hint: 'örn: Ali\'nin Sunucusu, Ev Sunucusu...'),
              ),
              const SizedBox(height: 12),
              const Text('SUNUCU URL\'İ',
                  style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1)),
              const SizedBox(height: 6),
              TextField(
                controller: _hostCtrl,
                style: const TextStyle(color: Colors.white),
                keyboardType: TextInputType.url,
                decoration: _input(
                    hint: 'https://random.trycloudflare.com'),
              ),
              const SizedBox(height: 4),
              const Text(
                'Arkadaşının paylaştığı Cloudflare Tunnel URL\'ini yapıştır.',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
              const SizedBox(height: 14),
              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.redAccent)),
                ),
                const SizedBox(height: 10),
              ],
              if (_testResult != null) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: (_testResult!.ok
                            ? Colors.greenAccent
                            : Colors.redAccent)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _testResult!.ok
                            ? Icons.check_circle
                            : Icons.error_outline,
                        color: _testResult!.ok
                            ? Colors.greenAccent
                            : Colors.redAccent,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _testResult!.ok
                              ? 'Bağlanıldı (${_testResult!.rttMs} ms)${_testResult!.serverName != null ? " — ${_testResult!.serverName}" : ""}'
                              : _testResult!.error ?? 'Bağlanılamadı',
                          style: TextStyle(
                            color: _testResult!.ok
                                ? Colors.greenAccent
                                : Colors.redAccent,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Row(
                children: [
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white70,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 12),
                    ),
                    onPressed: _testing ? null : _test,
                    icon: _testing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white54),
                          )
                        : const Icon(Icons.network_ping, size: 16),
                    label: const Text('Test Et'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('İptal',
                        style: TextStyle(color: Colors.white70)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF5865F2)),
                    onPressed: _save,
                    child: Text(isEdit ? 'Güncelle' : 'Kaydet'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _input({String? hint}) => InputDecoration(
        isDense: true,
        filled: true,
        fillColor: const Color(0xFF202225),
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide.none,
        ),
      );
}
