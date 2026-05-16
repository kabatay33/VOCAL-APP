import 'package:flutter/material.dart';
import '../api.dart';

/// Sunucu ayarları dialog'u — Genel + Roller + Üyeler sekmeleri.
class ServerSettingsDialog extends StatefulWidget {
  final String token;
  final ServerInfo server;
  const ServerSettingsDialog({
    super.key,
    required this.token,
    required this.server,
  });

  @override
  State<ServerSettingsDialog> createState() => _ServerSettingsDialogState();
}

class _ServerSettingsDialogState extends State<ServerSettingsDialog> {
  int _tab = 1; // 0=Genel, 1=Roller (varsayılan)
  List<Role> _roles = [];
  bool _loadingRoles = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRoles();
  }

  Future<void> _loadRoles() async {
    setState(() {
      _loadingRoles = true;
      _error = null;
    });
    try {
      final roles = await Api.getServerRoles(widget.token, widget.server.id);
      if (!mounted) return;
      setState(() {
        _roles = roles;
        _loadingRoles = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loadingRoles = false;
      });
    }
  }

  bool get _canManageRoles =>
      widget.server.hasPermission(Permissions.manageRoles);

  Future<void> _openRoleEditor({Role? role}) async {
    final result = await showDialog<Role>(
      context: context,
      builder: (ctx) => _RoleEditorDialog(
        token: widget.token,
        serverId: widget.server.id,
        role: role,
      ),
    );
    if (result != null) {
      await _loadRoles();
    }
  }

  Future<void> _deleteRole(Role role) async {
    if (role.isDefault) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2F3136),
        title: Text('"${role.name}" rolü silinsin mi?',
            style: const TextStyle(color: Colors.white)),
        content: const Text(
          'Bu rolü olan tüm üyeler rolü kaybeder.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('İptal'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await Api.deleteRole(widget.token, role.id);
      await _loadRoles();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Hata: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF36393F),
      insetPadding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800, maxHeight: 600),
        child: Row(
          children: [
            // Sol: sekme listesi
            SizedBox(
              width: 200,
              child: Container(
                color: const Color(0xFF2F3136),
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        widget.server.name,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _sideItem('Genel', 0, Icons.tune),
                    _sideItem('Roller', 1, Icons.shield),
                  ],
                ),
              ),
            ),
            // Sağ: içerik
            Expanded(
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: _tab == 0 ? _buildGeneralTab() : _buildRolesTab(),
                  ),
                  Positioned(
                    right: 8,
                    top: 8,
                    child: IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sideItem(String label, int idx, IconData icon) {
    final active = _tab == idx;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _tab = idx),
        child: Container(
          color: active ? const Color(0xFF393C43) : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(icon,
                  size: 16,
                  color: active ? Colors.white : Colors.white60),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: active ? Colors.white : Colors.white70,
                  fontWeight: active ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGeneralTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Genel',
            style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        _infoCard('Sunucu Adı', widget.server.name),
        const SizedBox(height: 12),
        _infoCard('Davet Kodu', widget.server.inviteCode),
        const SizedBox(height: 12),
        _infoCard(
            'Senin Rolün', widget.server.isOwner ? 'Sahip' : 'Üye'),
      ],
    );
  }

  Widget _infoCard(String label, String value) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2F3136),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1)),
          const SizedBox(height: 4),
          SelectableText(value,
              style: const TextStyle(color: Colors.white, fontSize: 15)),
        ],
      ),
    );
  }

  Widget _buildRolesTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Roller',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            const Spacer(),
            if (_canManageRoles)
              FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF5865F2)),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Yeni Rol'),
                onPressed: () => _openRoleEditor(),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (!_canManageRoles)
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline,
                    color: Colors.orangeAccent, size: 14),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Rol yönetme yetkin yok — rolleri yalnızca görüntüleyebilirsin.',
                    style: TextStyle(
                        color: Colors.orangeAccent, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Expanded(
          child: _loadingRoles
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Text(_error!,
                          style: const TextStyle(color: Colors.redAccent)))
                  : ListView.builder(
                      itemCount: _roles.length,
                      itemBuilder: (_, i) => _roleListItem(_roles[i]),
                    ),
        ),
      ],
    );
  }

  Widget _roleListItem(Role role) {
    final color = _parseHexColor(role.color);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2F3136),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      role.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (role.isDefault) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF40444B),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: const Text(
                          'VARSAYILAN',
                          style: TextStyle(
                              color: Colors.white54,
                              fontSize: 9,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _permissionSummary(role.permissions),
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (_canManageRoles) ...[
            IconButton(
              icon: const Icon(Icons.edit,
                  size: 16, color: Colors.white54),
              tooltip: 'Düzenle',
              onPressed: () => _openRoleEditor(role: role),
            ),
            if (!role.isDefault)
              IconButton(
                icon: const Icon(Icons.delete,
                    size: 16, color: Colors.redAccent),
                tooltip: 'Sil',
                onPressed: () => _deleteRole(role),
              ),
          ],
        ],
      ),
    );
  }

  String _permissionSummary(int perms) {
    final names = <String>[];
    for (final entry in Permissions.labels.entries) {
      if ((perms & entry.key) == entry.key) names.add(entry.value);
    }
    if (names.isEmpty) return 'Yetki yok';
    if (names.length > 3) {
      return '${names.take(3).join(', ')} ve ${names.length - 3} diğer';
    }
    return names.join(', ');
  }
}

Color _parseHexColor(String hex) {
  final clean = hex.replaceAll('#', '');
  if (clean.length != 6) return const Color(0xFF99AAB5);
  return Color(int.parse('FF$clean', radix: 16));
}

/// Tek bir rolü oluşturma/düzenleme dialog'u
class _RoleEditorDialog extends StatefulWidget {
  final String token;
  final int serverId;
  final Role? role; // null = yeni rol
  const _RoleEditorDialog({
    required this.token,
    required this.serverId,
    this.role,
  });

  @override
  State<_RoleEditorDialog> createState() => _RoleEditorDialogState();
}

class _RoleEditorDialogState extends State<_RoleEditorDialog> {
  late final TextEditingController _nameCtrl;
  late String _color;
  late int _perms;
  bool _saving = false;
  String? _error;

  static const _palette = [
    '#99AAB5', '#1ABC9C', '#2ECC71', '#3498DB',
    '#9B59B6', '#E91E63', '#F1C40F', '#E67E22',
    '#E74C3C', '#95A5A6', '#607D8B', '#ED4245',
  ];

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.role?.name ?? '');
    _color = widget.role?.color ?? '#99AAB5';
    _perms = widget.role?.permissions ?? 0;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  bool get _isEdit => widget.role != null;
  bool get _isDefault => widget.role?.isDefault == true;

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (!_isDefault && name.isEmpty) {
      setState(() => _error = 'Rol adı boş olamaz');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      Role result;
      if (_isEdit) {
        await Api.updateRole(
          widget.token,
          widget.role!.id,
          name: _isDefault ? null : name,
          color: _color,
          permissions: _perms,
        );
        result = Role(
          id: widget.role!.id,
          serverId: widget.role!.serverId,
          name: _isDefault ? widget.role!.name : name,
          color: _color,
          permissions: _perms,
          position: widget.role!.position,
          isDefault: widget.role!.isDefault,
        );
      } else {
        result = await Api.createRole(
          widget.token,
          widget.serverId,
          name: name,
          color: _color,
          permissions: _perms,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _togglePerm(int bit) {
    setState(() {
      if ((_perms & bit) == bit) {
        _perms &= ~bit;
      } else {
        _perms |= bit;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF2F3136),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.shield,
                      color: Color(0xFF5865F2), size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _isEdit ? 'Rolü Düzenle' : 'Yeni Rol',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (!_isDefault) ...[
                const Text('ROL ADI',
                    style: TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1)),
                const SizedBox(height: 6),
                TextField(
                  controller: _nameCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'örn: Moderatör',
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: const Color(0xFF202225),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              const Text('RENK',
                  style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final c in _palette)
                    GestureDetector(
                      onTap: () => setState(() => _color = c),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: _parseHexColor(c),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _color == c
                                ? Colors.white
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('YETKİLER',
                  style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1)),
              const SizedBox(height: 6),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final cat in Permissions.categories) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 6, bottom: 4),
                          child: Text(
                            cat.$1.toUpperCase(),
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                        for (final bit in cat.$2)
                          _permRow(bit, Permissions.labels[bit] ?? '?'),
                      ],
                    ],
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!,
                    style: const TextStyle(color: Colors.redAccent)),
              ],
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed:
                        _saving ? null : () => Navigator.of(context).pop(),
                    child: const Text('İptal',
                        style: TextStyle(color: Colors.white70)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF5865F2)),
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Text(_isEdit ? 'Kaydet' : 'Oluştur'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _permRow(int bit, String label) {
    final on = (_perms & bit) == bit;
    return InkWell(
      onTap: () => _togglePerm(bit),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Checkbox(
              value: on,
              onChanged: (_) => _togglePerm(bit),
              activeColor: const Color(0xFF5865F2),
            ),
            Expanded(
              child: Text(label,
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }
}
