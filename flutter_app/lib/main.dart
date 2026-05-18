import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
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
  // Endless-loop önleme: LOCK FILE pattern. Updater discord_clone'u
  // başlatmadan önce %TEMP%\vocal_app_skip_updater yazar; biz görünce
  // dosyayı sileriz ve updater'ı tetiklemeyiz.
  // (Flutter Windows runner argüman/env iletimi güvenilmez olabilir, lock
  // file ile bulletproof yaklaşım.)
  if (!kIsWeb && Platform.isWindows) {
    if (_shouldSkipUpdater()) {
      // Updater bizi yeni başlattı, döngüye girme
      debugPrint('[MAIN] Lock file bulundu — updater atlandi');
    } else {
      if (await _trySpawnUpdater()) {
        // Updater başlatıldı, biz çıkıyoruz. Updater check yapıp gerekirse
        // güncelleyecek ve discord_clone'u lock file ile relaunch edecek.
        exit(0);
      }
      // Updater bulunamadı — normal akışla devam et
    }
  }

  if (!kIsWeb &&
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    await windowManager.ensureInitialized();
    // Cercevesiz (frameless) tasarim — kendi title bar'imizi cizdirecegiz.
    const opts = WindowOptions(
      title: 'LocalHub',
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Color(0xFF202225),
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.setTitle('LocalHub');
      await windowManager.show();
      await windowManager.focus();
    });
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

/// Updater tarafından bırakılan lock file var mı? Varsa updater'ı spawn
/// etme — biz az önce updater tarafından başlatıldık (döngü önleme).
/// Lock file: %TEMP%\vocal_app_skip_updater  (30 sn'den eski ise stale say)
bool _shouldSkipUpdater() {
  try {
    final tempPath =
        Platform.environment['TEMP'] ?? Directory.systemTemp.path;
    // Platform.pathSeparator kullanmak \v escape sequence sorununu önler
    final lock =
        File('$tempPath${Platform.pathSeparator}vocal_app_skip_updater');
    if (!lock.existsSync()) return false;
    final age = DateTime.now().difference(lock.lastModifiedSync());
    if (age.inSeconds > 30) {
      // Stale lock — yine atlayalım ama dosyayı temizle
      try {
        lock.deleteSync();
      } catch (_) {}
      return false;
    }
    // Dosyayı tüketelim — sonraki açılışta updater normal şekilde çalışsın
    try {
      lock.deleteSync();
    } catch (_) {}
    return true;
  } catch (_) {
    return false;
  }
}

/// `updater\updater.exe` varsa Win32 CreateProcessW + CREATE_NO_WINDOW ile
/// invisible spawn et. Cmd penceresi açılmaz.
/// Dönüş: true = updater başlatıldı (biz exit'lemeliyiz), false = updater yok.
Future<bool> _trySpawnUpdater() async {
  try {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final updaterPath =
        '$exeDir${Platform.pathSeparator}updater${Platform.pathSeparator}updater.exe';
    if (!File(updaterPath).existsSync()) {
      debugPrint('[MAIN] updater.exe bulunamadi: $updaterPath');
      return false;
    }
    debugPrint('[MAIN] Updater invisible spawn ediliyor: $updaterPath');
    final ok = _invisibleSpawn(
      updaterPath,
      const [],
      File(updaterPath).parent.path,
    );
    return ok;
  } catch (e) {
    debugPrint('[MAIN] updater spawn hatasi: $e');
    return false;
  }
}

/// Win32 CreateProcessW + CREATE_NO_WINDOW + DETACHED_PROCESS.
/// Konsol penceresi açmadan + parent öldükten sonra da yaşamaya devam eder.
bool _invisibleSpawn(String exePath, List<String> args, String workingDir) {
  try {
    // Win32 sabitleri
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

    // STARTUPINFOW: 104 bytes
    final si = calloc<Uint8>(104);
    si.cast<Uint32>().value = 104; // cb = sizeof(STARTUPINFOW)
    // PROCESS_INFORMATION: 24 bytes (hProcess, hThread, dwProcessId, dwThreadId)
    final pi = calloc<Uint8>(24);

    // CommandLine'i quoted exe + args
    final cmdBuf = StringBuffer('"$exePath"');
    for (final a in args) {
      cmdBuf.write(' "$a"');
    }
    final cmdLine = cmdBuf.toString().toNativeUtf16();
    final dirPtr = workingDir.toNativeUtf16();

    try {
      final ok = createProcessW(
        nullptr, // ApplicationName (commandLine içinde)
        cmdLine,
        nullptr,
        nullptr,
        0, // inheritHandles = false
        flags,
        nullptr,
        dirPtr,
        si,
        pi,
      );
      if (ok == 0) {
        return false;
      }
      // Process/Thread handle'larını kapat (process çalışmaya devam eder)
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
    debugPrint('[MAIN] _invisibleSpawn hata: $e');
    return false;
  }
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LocalHub',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF36393F),
      ),
      // Tum sayfalari kendi title bar'imizla saralim — cercevesiz pencere.
      builder: (context, child) => _AppFrame(child: child),
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

/// Tum sayfalari saran kabuk: ust kisimda kendi title bar'imiz, alt kisimda
/// gercek icerik. Pencere cercevesiz (TitleBarStyle.hidden).
class _AppFrame extends StatelessWidget {
  final Widget? child;
  const _AppFrame({this.child});

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || !Platform.isWindows) {
      // Sadece Windows desktop'ta custom title bar; diger platformlarda
      // sistem cercevesini kullan.
      return child ?? const SizedBox.shrink();
    }
    return Material(
      color: const Color(0xFF36393F),
      child: Column(
        children: [
          const _TitleBar(),
          Expanded(child: child ?? const SizedBox.shrink()),
        ],
      ),
    );
  }
}

/// Ust title bar — surukle alani + min/max/close butonlari.
/// "ayarlar butonunun bir ustunde" durur (chat ekraninda AppBar'in ustunde).
class _TitleBar extends StatefulWidget {
  const _TitleBar();

  @override
  State<_TitleBar> createState() => _TitleBarState();
}

class _TitleBarState extends State<_TitleBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _refreshMaximized();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _refreshMaximized() async {
    final m = await windowManager.isMaximized();
    if (mounted) setState(() => _maximized = m);
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _maximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _maximized = false);
  }

  @override
  Widget build(BuildContext context) {
    // AppBar ile ayni renk — boylece sinir gozukmesin.
    return Container(
      height: 32,
      color: const Color(0xFF202225),
      child: Row(
        children: [
          // Sol: app icon + ad + surukle alani
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => windowManager.startDragging(),
              onDoubleTap: () async {
                if (await windowManager.isMaximized()) {
                  windowManager.unmaximize();
                } else {
                  windowManager.maximize();
                }
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Icon(Icons.hub, size: 14, color: Color(0xFF5865F2)),
                    SizedBox(width: 8),
                    Text(
                      'LocalHub',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Sag: pencere kontrolleri
          _winBtn(
            icon: Icons.minimize,
            tooltip: 'Kucult',
            onTap: () => windowManager.minimize(),
          ),
          _winBtn(
            icon: _maximized ? Icons.filter_none : Icons.crop_square,
            iconSize: _maximized ? 11 : 14,
            tooltip: _maximized ? 'Eski boyut' : 'Tam ekran',
            onTap: () async {
              if (await windowManager.isMaximized()) {
                windowManager.unmaximize();
              } else {
                windowManager.maximize();
              }
            },
          ),
          _winBtn(
            icon: Icons.close,
            tooltip: 'Kapat',
            hoverColor: const Color(0xFFE81123),
            onTap: () => windowManager.close(),
          ),
        ],
      ),
    );
  }

  Widget _winBtn({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    double iconSize = 14,
    Color? hoverColor,
  }) {
    return _WinButton(
      icon: icon,
      tooltip: tooltip,
      onTap: onTap,
      iconSize: iconSize,
      hoverColor: hoverColor,
    );
  }
}

class _WinButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double iconSize;
  final Color? hoverColor;
  const _WinButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.iconSize,
    this.hoverColor,
  });

  @override
  State<_WinButton> createState() => _WinButtonState();
}

class _WinButtonState extends State<_WinButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bg = _hover
        ? (widget.hoverColor ?? const Color(0xFF2F3136))
        : Colors.transparent;
    final fg = _hover && widget.hoverColor != null
        ? Colors.white
        : Colors.white70;
    // KRITIK: Tooltip kaldirildi — pencere en ustte oldugundan tooltip box'i
    // bar uzerine dusup pointer yakaliyor + bar beyazlasiyor gibi
    // gozukuyordu. Ayrica SizedBox + HitTestBehavior.opaque ile button'un
    // tikla davranisi sadece kendi 46x32 alanina hapsedilir; aksi halde
    // GestureDetector default deferToChild davranisi ile boslukta tiklamalari
    // diger handler'lara devrediyor.
    return SizedBox(
      width: 46,
      height: 32,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: ColoredBox(
            color: bg,
            child: Center(
              child: Icon(
                widget.icon,
                size: widget.iconSize,
                color: fg,
                semanticLabel: widget.tooltip,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
