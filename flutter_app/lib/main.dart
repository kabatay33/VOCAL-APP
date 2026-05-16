import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'api.dart';
import 'backend_process_service.dart';
import 'config.dart';
import 'screens/chat_screen.dart';
import 'screens/login_screen.dart';
import 'storage.dart';
import 'tray_service.dart';
import 'update_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kIsWeb &&
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    await windowManager.ensureInitialized();
    // System tray + pencere kapatma yakalama
    await TrayService().init();
  }

  // Kayıtlı backend IP'sini yükle (login ekranından ayarlanıyor)
  final savedHost = await Storage.getServerHost();
  if (savedHost != null && savedHost.isNotEmpty) {
    Config.setHost(savedHost);
  }

  // Backend'i app yaşam döngüsüyle birlikte başlat — node bulunamazsa veya
  // port 3000 zaten kullanılıyorsa sessizce atlar (friend cihazları için)
  if (!kIsWeb && Platform.isWindows) {
    await BackendProcessService.instance.start();
  }

  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Discord Clone',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF36393F),
      ),
      // İlk widget: UpdateGate — auto-updater splash. Update yoksa veya
      // backend ulaşılamıyorsa Bootstrap'e geçer.
      home: const UpdateGate(),
    );
  }
}

/// UpdateGate sonrası asıl uygulama yönlendirmesi: token varsa ChatScreen,
/// yoksa LoginScreen.
class Bootstrap extends StatefulWidget {
  const Bootstrap({super.key});

  @override
  State<Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<Bootstrap> {
  @override
  void initState() {
    super.initState();
    _decideRoute();
  }

  Future<void> _decideRoute() async {
    final saved = await Storage.load();
    if (!mounted) return;
    if (saved == null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
      return;
    }
    // Token ile güncel profili çek (email dahil)
    try {
      final me = await Api.getMe(saved.token);
      if (!mounted) return;
      final auth = AuthResult(
        token: saved.token,
        userId: me.id,
        username: me.username,
        email: me.email,
        avatarUrl: me.avatarUrl,
      );
      await Storage.setLastUsername(me.username);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => ChatScreen(auth: auth)),
      );
    } catch (_) {
      // Token geçersiz veya sunucuya bağlanılamıyor — login ekranına dön
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(color: Color(0xFF5865F2)),
      ),
    );
  }
}
