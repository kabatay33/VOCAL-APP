import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'api.dart';
import 'backend_process_service.dart';
import 'config.dart';
import 'input_manager.dart';
import 'screens/chat_screen.dart';
import 'screens/login_screen.dart';
import 'storage.dart';
import 'tray_service.dart';
import 'update_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // İlk açılışta updater'ı spawn et + kendini kapat.
  // Endless-loop önleme: ENV var VOCAL_NO_UPDATER=1 — updater discord_clone'u
  // bu env ile başlatır; biz görünce updater'ı bir daha tetiklemeyiz.
  // (Flutter Windows runner main() argümanlarını engine'e pass etmiyor,
  // bu yüzden command-line arg yerine env var kullanıyoruz.)
  if (!kIsWeb &&
      Platform.isWindows &&
      Platform.environment['VOCAL_NO_UPDATER'] != '1') {
    if (await _trySpawnUpdater()) {
      // Updater başlatıldı, biz çıkıyoruz. Updater check yapacak ve
      // gerekirse güncelleyip discord_clone'u VOCAL_NO_UPDATER=1 ile relaunch.
      exit(0);
    }
    // Updater bulunamadı veya başlatılamadı — normal akışla devam et
  }

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
    // Backend port 3000'de hazır olana kadar bekle (max 10 sn)
    final backendReady = await BackendProcessService.instance.waitForReady(timeoutSeconds: 10);
    if (backendReady) {
      debugPrint('[MAIN] Backend hazır — port 3000 aktif');
    } else {
      debugPrint('[MAIN] Backend hazır değil — splash ekranı bekleyecek');
    }
  }

  // Input injection manager'ı başlat (Windows native SendInput)
  await InputManager.init();

  runApp(const App());
}

/// `updater\updater.exe` dosyası bizim yanımızda varsa onu spawn eder.
/// Updater check + (gerekirse) update + discord_clone --no-updater ile relaunch
/// yapar.
///
/// Dönüş: true = updater başlatıldı (biz exit'lemeliyiz), false = updater yok
/// (normal akışla devam edilecek).
Future<bool> _trySpawnUpdater() async {
  try {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final updaterPath =
        '$exeDir${Platform.pathSeparator}updater${Platform.pathSeparator}updater.exe';
    if (!File(updaterPath).existsSync()) {
      debugPrint('[MAIN] updater.exe bulunamadi: $updaterPath');
      return false;
    }
    debugPrint('[MAIN] Updater spawn ediliyor: $updaterPath');
    // cmd /c start ile detached — discord_clone exit edince de updater yaşar
    await Process.start(
      'cmd',
      ['/c', 'start', '""', '/D', File(updaterPath).parent.path, updaterPath],
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
    return true;
  } catch (e) {
    debugPrint('[MAIN] updater spawn hatasi: $e');
    return false;
  }
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
