import 'package:flutter/material.dart';
import '../api.dart';
import '../config.dart';
import '../storage.dart';
import 'chat_screen.dart';
import 'hamachi_network_dialog.dart';

/// Sadeleştirilmiş giriş ekranı.
///
/// Sadece **kullanıcı adı** ile giriş — şifre/email yok. Backend var olan
/// kullanıcıyı bulur, yoksa otomatik oluşturur (`POST /api/login {username}`).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameCtrl = TextEditingController();
  final _serverCtrl = TextEditingController();
  bool _isLoading = false;
  bool _rememberMe = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSavedPrefs();
  }

  Future<void> _loadSavedPrefs() async {
    final savedHost = await Storage.getServerHost();
    if (savedHost != null && savedHost.isNotEmpty) {
      _serverCtrl.text = savedHost;
    } else {
      _serverCtrl.text = Config.defaultHost;
    }
    final remember = await Storage.getRememberMe();
    final lastUsername = await Storage.getLastUsername();
    if (mounted) {
      setState(() {
        _rememberMe = remember;
        if (lastUsername != null) _usernameCtrl.text = lastUsername;
      });
    }
  }

  Future<void> _openServerList() async {
    final cachedUser = await Storage.getLastUsername();
    if (!mounted) return;
    final selected = await showDialog<String>(
      context: context,
      builder: (_) => HamachiNetworkDialog(
        currentHost: _serverCtrl.text,
        currentUsername: cachedUser,
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => _serverCtrl.text = selected);
    Config.setHost(selected);
    await Storage.setServerHost(selected);
    await Storage.touchServer(selected);
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _serverCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _usernameCtrl.text.trim();
    final server = _serverCtrl.text.trim();

    if (username.length < 3) {
      setState(() => _error = 'Kullanıcı adı en az 3 karakter olmalı');
      return;
    }
    if (server.isEmpty) {
      setState(() => _error = 'Sunucu adresi boş olamaz');
      return;
    }

    Config.setHost(server);
    await Storage.setServerHost(server);

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final result = await Api.login(username);
      await Storage.setRememberMe(_rememberMe);
      if (_rememberMe) {
        await Storage.save(
          token: result.token,
          username: result.username,
          userId: result.userId,
        );
      } else {
        await Storage.clear();
      }
      await Storage.setLastUsername(result.username);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => ChatScreen(auth: result)),
      );
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Bağlantı hatası: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF36393F),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Card(
              color: const Color(0xFF2F3136),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.hub,
                        size: 64, color: Color(0xFF5865F2)),
                    const SizedBox(height: 16),
                    const Text(
                      'LocalHub',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Kullanici adini yaz ve giris yap',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _usernameCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: _input('Kullanıcı adı').copyWith(
                        helperText: 'Diğer kullanıcılara görünür ad',
                        helperStyle:
                            const TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                      onSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: 8),
                    InkWell(
                      onTap: () =>
                          setState(() => _rememberMe = !_rememberMe),
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Checkbox(
                              value: _rememberMe,
                              onChanged: (v) =>
                                  setState(() => _rememberMe = v ?? false),
                              activeColor: const Color(0xFF5865F2),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                            ),
                            const SizedBox(width: 4),
                            const Expanded(
                              child: Text(
                                'Beni hatırla',
                                style: TextStyle(
                                    color: Colors.white70, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    InkWell(
                      onTap: _openServerList,
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF202225),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.dns,
                                size: 16, color: Color(0xFF5865F2)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'SUNUCU',
                                    style: TextStyle(
                                      color: Colors.white38,
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1,
                                    ),
                                  ),
                                  Text(
                                    _serverCtrl.text.isEmpty
                                        ? Config.defaultHost
                                        : _serverCtrl.text,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(Icons.unfold_more,
                                size: 16, color: Colors.white54),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_error != null)
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Colors.redAccent),
                        ),
                      ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _isLoading ? null : _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF5865F2),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Giriş Yap'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _input(String label) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        filled: true,
        fillColor: const Color(0xFF202225),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide.none,
        ),
      );
}
