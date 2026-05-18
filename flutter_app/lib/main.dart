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

  // Eski stale lock file temizliği
  if (!kIsWeb && Platform.isWindows) {
    _cleanupStaleLockFile();
  }

  // Window manager'i hemen hazırla (FAST PATH) — backend bekleme YOK!
  // Beyaz ekran çıkmasın diye Flutter ilk frame'i render etmeden window
  // gösterilmiyor; render edince hemen splash UI çıkar.
  if (!kIsWeb &&
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    await windowManager.ensureInitialized();
    const opts = WindowOptions(
      title: 'LocalHub',
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Color(0xFF1E1F22),
      // skipTaskbar: false (default), kullanıcı taskbar'da görsün
    );
    // waitUntilReadyToShow callback'inde HENÜZ show etmiyoruz —
    // ilk Flutter frame render edildikten sonra göstereceğiz.
    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.setTitle('LocalHub');
      // show + focus burada yapılmıyor → beyaz ekran yok
    });
  }

  // Kayıtlı backend IP'sini yükle (login ekranından ayarlanıyor)
  final savedHost = await Storage.getServerHost();
  if (savedHost != null && savedHost.isNotEmpty) {
    Config.setHost(savedHost);
  }

  // Input injection manager'ı başlat (Windows native SendInput)
  await InputManager.init();

  // runApp HEMEN çağrılıyor — backend startup + waitForReady artık async
  // olarak splash sırasında çalışıyor (UpdateGate'in waitForBackend kısmı
  // zaten bekliyordu, burada da fire-and-forget olarak başlatıyoruz).
  if (!kIsWeb && Platform.isWindows) {
    // Fire-and-forget: backend'i arka planda başlat, runApp'i bloklama
    // ignore: discarded_futures
    BackendProcessService.instance.start().then((_) {
      debugPrint('[MAIN] Backend process spawn tamamlandı');
    });
  }

  runApp(const App());

  // İlk frame render edildikten sonra pencereyi göster + tray init.
  // Bu sayede pencere açıldığı an splash UI hazır olur, beyaz ekran yok.
  if (!kIsWeb &&
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await windowManager.show();
        await windowManager.focus();
        await TrayService().init();
      } catch (e) {
        debugPrint('[MAIN] Window/tray init hata: $e');
      }
    });
  }
}

/// Win32 CreateProcessW + CREATE_NO_WINDOW + DETACHED_PROCESS.
/// Konsol penceresi açmadan + parent öldükten sonra da yaşamaya devam eder.
/// Apply script (update) spawn için kullanılır — kullanıcı CMD penceresi
/// görmez.
bool invisibleSpawn(String exePath, List<String> args, String workingDir) {
  try {
    const createNoWindow = 0x08000000;
    const detachedProcess = 0x00000008;
    const createNewProcessGroup = 0x00000200;
    const flags = createNoWindow | detachedProcess | createNewProcessGroup;

    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final createProcessW = kernel32.lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>,
            Pointer<Void>, Int32, Uint32, Pointer<Void>, Pointer<Utf16>,
            Pointer<Uint8>, Pointer<Uint8>),
        int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>,
            Pointer<Void>, int, int, Pointer<Void>, Pointer<Utf16>,
            Pointer<Uint8>, Pointer<Uint8>)>('CreateProcessW');
    final closeHandle = kernel32.lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('CloseHandle');

    // STARTUPINFOW: 104 bytes (sizeof)
    final si = calloc<Uint8>(104);
    si.cast<Uint32>().value = 104;
    // PROCESS_INFORMATION: 24 bytes
    final pi = calloc<Uint8>(24);

    final cmdBuf = StringBuffer('"$exePath"');
    for (final a in args) {
      cmdBuf.write(' "$a"');
    }
    final cmdLine = cmdBuf.toString().toNativeUtf16();
    final dirPtr = workingDir.toNativeUtf16();

    try {
      final ok = createProcessW(
        nullptr,
        cmdLine,
        nullptr,
        nullptr,
        0,
        flags,
        nullptr,
        dirPtr,
        si,
        pi,
      );
      if (ok == 0) return false;
      final piPtr = pi.cast<IntPtr>();
      closeHandle(Pointer<Void>.fromAddress(piPtr.value));
      closeHandle(Pointer<Void>.fromAddress((piPtr + 1).value));
      return true;
    } finally {
      malloc.free(cmdLine);
      malloc.free(dirPtr);
      malloc.free(si);
      malloc.free(pi);
    }
  } catch (e) {
    debugPrint('[MAIN] invisibleSpawn hata: $e');
    return false;
  }
}

/// Eski updater.exe spawn akışından kalan stale lock file'ı temizle.
void _cleanupStaleLockFile() {
  try {
    final tempPath =
        Platform.environment['TEMP'] ?? Directory.systemTemp.path;
    final lock =
        File('$tempPath${Platform.pathSeparator}vocal_app_skip_updater');
    if (lock.existsSync()) {
      try {
        lock.deleteSync();
      } catch (_) {}
    }
  } catch (_) {}
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
