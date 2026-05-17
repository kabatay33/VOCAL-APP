import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:window_manager/window_manager.dart';
import '../api.dart';
import '../config.dart';
import '../input_manager.dart';
import '../screen_share_options.dart';
import '../sound_service.dart';
import '../storage.dart';
import '../voice_manager.dart';
import '../widgets/user_avatar.dart';
import 'login_screen.dart';
import 'hamachi_network_dialog.dart';
import 'server_settings_dialog.dart';

class ChatScreen extends StatefulWidget {
  final AuthResult auth;
  const ChatScreen({super.key, required this.auth});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  List<Channel> _channels = [];
  Channel? _selectedChannel;
  final Map<int, List<Message>> _messages = {};
  final Map<int, List<({int userId, String username, bool screenSharing, bool cameraSharing, String? avatarUrl})>>
      _voiceMembers = {};
  final _msgCtrl = TextEditingController();
  final Map<int, RTCVideoRenderer> _audioRenderers = {};
  final Map<int, RTCVideoRenderer> _screenRenderers = {};
  final Map<int, RTCVideoRenderer> _cameraRenderers = {};
  RTCVideoRenderer? _localScreenRenderer;
  RTCVideoRenderer? _localCameraRenderer;
  int? _focusedScreenUserId;
  // Aktif olarak büyük ekranda gösterilen kamera (null = ekran paylaşımı odakta)
  int? _focusedCameraUserId;
  // Local preview overlay (kendi yayınımızın küçük canlı önizlemesi)
  Offset _previewOffset = const Offset(20, 20); // sağ-alt köşeden uzaklık
  bool _previewVisible = true;

  late final VoiceManager _voice;
  late AuthResult _auth;
  final _scrollCtrl = ScrollController();
  bool _connected = false;
  String? _wsError;
  ScreenShareOptions _shareOptions = ScreenShareOptions.defaults;
  List<ServerInfo> _servers = [];
  ServerInfo? _activeServer;
  List<UserProfile> _allUsers = [];
  Set<int> _onlineUserIds = {};
  bool _membersVisible = true;
  Timer? _pingTimer;
  int? _lastPingMs;

  @override
  void initState() {
    super.initState();
    _auth = widget.auth;
    _voice = VoiceManager(sendSignal: _sendVoiceSignal);
    _voice.setMyUserId(_auth.userId);
    _voice.onScreenStateChanged = _notifyScreenState;
    _voice.onCameraStateChanged = _notifyCameraState;
    _voice.onInputEvent = (event) => InputManager.handleInputEvent(event);
    _voice.addListener(_onVoiceChanged);
    _connectWs();
    _loadShareOptions();
    _loadPreferredAudioDevices();
    // _loadServers içinde sırayla channels + users de yüklenir
    _loadServers();
  }

  Future<void> _loadPreferredAudioDevices() async {
    try {
      final inputId = await Storage.getAudioInputId();
      if (inputId != null && inputId.isNotEmpty) {
        // Sesli kanalda değil → sadece tercih kaydedilir, join() sırasında kullanılır.
        await _voice.selectAudioInput(inputId);
      }
      final outputId = await Storage.getAudioOutputId();
      if (outputId != null && outputId.isNotEmpty) {
        await _voice.selectAudioOutput(outputId);
      }
      // Kamera tercihleri (cihaz + çözünürlük + FPS)
      final camId = await Storage.getCameraDeviceId();
      final camW = await Storage.getCameraWidth();
      final camFps = await Storage.getCameraFps();
      await _voice.setCameraPreferences(
        deviceId: camId,
        width: camW,
        fps: camFps,
      );
    } catch (e) {
      debugPrint('[CHAT] Kayıtlı ses/kamera cihazı yüklenemedi: $e');
    }
  }

  Future<void> _loadUsers() async {
    final activeServer = _activeServer;
    if (activeServer == null) return;
    try {
      final users =
          await Api.getServerMembers(_auth.token, activeServer.id);
      if (!mounted) return;
      setState(() => _allUsers = users);
    } catch (_) {/* sessizce yoksay */}
    // Üye panel görünürlük tercihini yükle (yalnız ilk kez)
    final visible = await Storage.getMembersPanelVisible();
    if (mounted) setState(() => _membersVisible = visible);
  }

  Future<void> _toggleMembersPanel() async {
    setState(() => _membersVisible = !_membersVisible);
    await Storage.setMembersPanelVisible(_membersVisible);
  }

  Future<void> _loadServers() async {
    try {
      final servers = await Api.getServers(_auth.token);
      if (!mounted) return;
      // En son seçili sunucuyu hatırla; yoksa ilk sunucuya geç
      final lastId = await Storage.getActiveServerId();
      ServerInfo? active;
      if (lastId != null) {
        for (final s in servers) {
          if (s.id == lastId) {
            active = s;
            break;
          }
        }
      }
      active ??= servers.isNotEmpty ? servers.first : null;
      setState(() {
        _servers = servers;
        _activeServer = active;
      });
      if (active != null) {
        await Storage.setActiveServerId(active.id);
        await _loadChannels();
        await _loadUsers();
      }
    } catch (e) {
      _showSnack('Sunucular alınamadı: $e');
    }
  }

  Future<void> _loadShareOptions() async {
    final opts = await ScreenShareOptions.load();
    if (mounted) setState(() => _shareOptions = opts);
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    _voice.removeListener(_onVoiceChanged);
    _voice.dispose();
    _wsSub?.cancel();
    _ws?.sink.close();
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    for (final r in _audioRenderers.values) {
      r.dispose();
    }
    for (final r in _screenRenderers.values) {
      r.dispose();
    }
    for (final r in _cameraRenderers.values) {
      r.dispose();
    }
    _localScreenRenderer?.dispose();
    _localCameraRenderer?.dispose();
    super.dispose();
  }

  void _notifyScreenState(bool sharing) {
    _ws?.sink.add(jsonEncode({
      'type': 'voice-screen-state',
      'sharing': sharing,
    }));
    if (sharing) {
      SoundService().playShareStarted();
    } else {
      SoundService().playShareStopped();
    }
  }

  void _notifyCameraState(bool sharing) {
    _ws?.sink.add(jsonEncode({
      'type': 'voice-camera-state',
      'sharing': sharing,
    }));
    if (sharing) {
      SoundService().playShareStarted();
    } else {
      SoundService().playShareStopped();
    }
  }

  Future<void> _toggleCamera() async {
    if (!_voice.inVoice) {
      _showSnack('Önce bir sesli kanala katıl');
      return;
    }
    try {
      if (_voice.isCameraSharing) {
        await _voice.stopCamera();
      } else {
        // Kamera izni iste
        final status = await Permission.camera.request();
        if (!status.isGranted) {
          _showSnack('Kamera izni gerekli');
          return;
        }
        await _voice.startCamera(
          deviceId: _voice.preferredCameraDeviceId,
        );
      }
    } catch (e) {
      _showErrorDialog('Kamera hatası', e.toString());
    }
  }

  void _onVoiceChanged() {
    _syncAudioRenderers();
    if (mounted) setState(() {});
  }

  Future<void> _syncAudioRenderers() async {
    final activeIds = <int>{};
    for (final peer in _voice.peers) {
      activeIds.add(peer.userId);
      // Audio renderer (sesi başlatmak için gerekli)
      if (peer.remoteAudioStream != null &&
          !_audioRenderers.containsKey(peer.userId)) {
        final r = RTCVideoRenderer();
        await r.initialize();
        r.srcObject = peer.remoteAudioStream;
        _audioRenderers[peer.userId] = r;
      }
      // Screen video renderer
      final existingScreen = _screenRenderers[peer.userId];
      if (peer.remoteScreenStream != null && existingScreen == null) {
        final r = RTCVideoRenderer();
        await r.initialize();
        r.srcObject = peer.remoteScreenStream;
        _screenRenderers[peer.userId] = r;
        // İlk gelen ekran paylaşımını otomatik odakla
        _focusedScreenUserId ??= peer.userId;
      } else if (peer.remoteScreenStream == null && existingScreen != null) {
        await existingScreen.dispose();
        _screenRenderers.remove(peer.userId);
        if (_focusedScreenUserId == peer.userId) _focusedScreenUserId = null;
      }
      // Camera video renderer
      final existingCam = _cameraRenderers[peer.userId];
      if (peer.remoteCameraStream != null && existingCam == null) {
        final r = RTCVideoRenderer();
        await r.initialize();
        r.srcObject = peer.remoteCameraStream;
        _cameraRenderers[peer.userId] = r;
      } else if (peer.remoteCameraStream == null && existingCam != null) {
        await existingCam.dispose();
        _cameraRenderers.remove(peer.userId);
        if (_focusedCameraUserId == peer.userId) _focusedCameraUserId = null;
      }
    }
    // Ayrılan kullanıcıların renderer'ları
    final toRemoveAudio = _audioRenderers.keys
        .where((id) => !activeIds.contains(id))
        .toList();
    for (final id in toRemoveAudio) {
      await _audioRenderers[id]!.dispose();
      _audioRenderers.remove(id);
    }
    final toRemoveScreen = _screenRenderers.keys
        .where((id) => !activeIds.contains(id))
        .toList();
    for (final id in toRemoveScreen) {
      await _screenRenderers[id]!.dispose();
      _screenRenderers.remove(id);
      if (_focusedScreenUserId == id) _focusedScreenUserId = null;
    }
    final toRemoveCam = _cameraRenderers.keys
        .where((id) => !activeIds.contains(id))
        .toList();
    for (final id in toRemoveCam) {
      await _cameraRenderers[id]!.dispose();
      _cameraRenderers.remove(id);
      if (_focusedCameraUserId == id) _focusedCameraUserId = null;
    }

    // Local screen renderer (kendi paylaştığımız ekran)
    if (_voice.isScreenSharing && _voice.localScreenStream != null) {
      if (_localScreenRenderer == null) {
        _localScreenRenderer = RTCVideoRenderer();
        await _localScreenRenderer!.initialize();
        _localScreenRenderer!.srcObject = _voice.localScreenStream;
      }
    } else if (_localScreenRenderer != null) {
      await _localScreenRenderer!.dispose();
      _localScreenRenderer = null;
    }

    // Local camera renderer (kendi kameramız)
    if (_voice.isCameraSharing && _voice.localCameraStream != null) {
      if (_localCameraRenderer == null) {
        _localCameraRenderer = RTCVideoRenderer();
        await _localCameraRenderer!.initialize();
        _localCameraRenderer!.srcObject = _voice.localCameraStream;
      }
    } else if (_localCameraRenderer != null) {
      await _localCameraRenderer!.dispose();
      _localCameraRenderer = null;
    }
  }

  Future<void> _loadChannels() async {
    final activeServer = _activeServer;
    if (activeServer == null) return;
    try {
      final list = await Api.getServerChannels(_auth.token, activeServer.id);
      if (!mounted) return;
      // Yalnız metin kanalı seçilebilir — sesli kanallar sadece sidebar'da
      final firstText = list
          .where((c) => !c.isVoice)
          .cast<Channel?>()
          .firstWhere((_) => true, orElse: () => null);
      setState(() {
        _channels = list;
        // Önceki seçili kanal bu serverda değilse, ilk metin kanalına geç
        if (_selectedChannel == null ||
            !list.any((c) => c.id == _selectedChannel!.id)) {
          _selectedChannel = firstText;
          _messages.clear();
        }
      });
      if (_selectedChannel != null) {
        await _loadMessages(_selectedChannel!.id);
      }
    } catch (e) {
      _showSnack('Kanallar yüklenemedi: $e');
    }
  }

  Future<void> _loadMessages(int channelId) async {
    try {
      final msgs = await Api.getChannelMessages(_auth.token, channelId);
      if (!mounted) return;
      setState(() => _messages[channelId] = msgs);
      _scrollToBottom();
    } catch (e) {
      _showSnack('Mesajlar yüklenemedi: $e');
    }
  }

  void _connectWs() {
    try {
      _ws = WebSocketChannel.connect(Uri.parse(Config.wsUrl(_auth.token)));
      _wsSub = _ws!.stream.listen(
        _onWsMessage,
        onError: (e) {
          if (mounted) {
            setState(() {
              _connected = false;
              _wsError = e.toString();
            });
          }
        },
        onDone: () {
          if (mounted) setState(() => _connected = false);
        },
      );
    } catch (e) {
      setState(() => _wsError = e.toString());
    }
  }

  void _startPingTimer() {
    _pingTimer?.cancel();
    // İlk pingi hemen gönder, sonra her 3 saniyede tekrar et
    _sendPing();
    _pingTimer = Timer.periodic(const Duration(seconds: 3), (_) => _sendPing());
  }

  void _sendPing() {
    if (!_connected || _ws == null) return;
    _ws!.sink.add(jsonEncode({
      'type': 'ping',
      'ts': DateTime.now().millisecondsSinceEpoch,
    }));
  }

  void _sendVoiceSignal(int toUserId, Map<String, dynamic> payload) {
    _ws?.sink.add(jsonEncode({
      'type': 'voice-signal',
      'toUserId': toUserId,
      'payload': payload,
    }));
  }

  void _onWsMessage(dynamic data) async {
    final msg = jsonDecode(data as String) as Map<String, dynamic>;
    final type = msg['type'] as String?;

    if (type == 'hello') {
      if (mounted) setState(() => _connected = true);
      _startPingTimer();
    } else if (type == 'pong') {
      final ts = msg['ts'] as int?;
      if (ts != null) {
        final rtt = DateTime.now().millisecondsSinceEpoch - ts;
        if (mounted) setState(() => _lastPingMs = rtt);
      }
    } else if (type == 'message') {
      final m = Message.fromJson(msg);
      setState(() {
        _messages.putIfAbsent(m.channelId, () => []).add(m);
      });
      if (m.channelId == _selectedChannel?.id) _scrollToBottom();
      // Mesaj sesi: başkası gönderdiyse çal. Aktif kanaldaysa ve pencere
      // odaktaysa daha sessiz olur; arkadaysa veya farklı kanaldaysa daha belirgin.
      if (m.userId != _auth.userId) {
        SoundService().playMessage();
      }
    } else if (type == 'voice-members') {
      final channelId = msg['channelId'] as int;
      final raw = msg['members'] as List;
      final members = raw
          .map((m) => (
                userId: m['userId'] as int,
                username: m['username'] as String,
                screenSharing: (m['screenSharing'] as bool?) ?? false,
                cameraSharing: (m['cameraSharing'] as bool?) ?? false,
                avatarUrl: m['avatar_url'] as String?,
              ))
          .toList();

      // Eğer bu bizim katıldığımız kanalsa, üye sayısı değişiminde ses çal
      if (_voice.currentChannelId == channelId) {
        final prev = _voiceMembers[channelId] ?? [];
        final prevIds = prev.map((m) => m.userId).toSet();
        final newIds = members.map((m) => m.userId).toSet();
        final joined = newIds.difference(prevIds);
        final left = prevIds.difference(newIds);
        // Kendi katılışımız için ses çalma (zaten biliyoruz)
        joined.remove(_auth.userId);
        if (joined.isNotEmpty) {
          SoundService().playUserJoinedVoice();
        } else if (left.isNotEmpty) {
          SoundService().playUserLeftVoice();
        }

        // Başkalarının ekran/kamera paylaşım transition'larını yakala
        // (kendi state'imiz callback'lerden çalınıyor — burada hariç tut)
        final prevByUser = {for (final p in prev) p.userId: p};
        for (final m in members) {
          if (m.userId == _auth.userId) continue;
          final old = prevByUser[m.userId];
          if (old == null) continue; // yeni katılan, başka bir ses zaten çalıyor
          if (!old.screenSharing && m.screenSharing) {
            SoundService().playShareStarted();
          } else if (old.screenSharing && !m.screenSharing) {
            SoundService().playShareStopped();
          }
          if (!old.cameraSharing && m.cameraSharing) {
            SoundService().playShareStarted();
          } else if (old.cameraSharing && !m.cameraSharing) {
            SoundService().playShareStopped();
          }
        }
      }

      setState(() => _voiceMembers[channelId] = members);
      await _voice.syncMembers(channelId, members.map((m) => m.userId).toList());
    } else if (type == 'voice-joined') {
      // Backend bize katıldığımızı ve mevcut üyeleri bildirdi
      final channelId = msg['channelId'] as int;
      final existingRaw = msg['existingMembers'] as List;
      final existing = existingRaw
          .map((m) => (
                userId: m['userId'] as int,
                username: m['username'] as String,
              ))
          .toList();
      await _voice.join(channelId, existing);
      SoundService().playSelfJoined();
    } else if (type == 'voice-signal') {
      await _voice.handleSignal(
        fromUserId: msg['fromUserId'] as int,
        fromUsername: msg['fromUsername'] as String,
        payload: Map<String, dynamic>.from(msg['payload'] as Map),
      );
    } else if (type == 'user-profile-updated') {
      final user = msg['user'] as Map<String, dynamic>;
      final userId = user['userId'] as int;
      final newUsername = user['username'] as String;
      final newAvatarUrl = user['avatar_url'] as String?;
      if (!mounted) return;
      setState(() {
        // Tüm kanal mesajlarındaki bu kullanıcının username/avatar'ını güncelle
        for (final entry in _messages.entries) {
          final list = entry.value;
          for (var i = 0; i < list.length; i++) {
            if (list[i].userId == userId) {
              list[i] = list[i].copyWith(
                username: newUsername,
                avatarUrl: newAvatarUrl,
              );
            }
          }
        }
        // Üye listesinde de güncelle
        _allUsers = _allUsers
            .map((u) => u.id == userId
                ? UserProfile(
                    id: u.id,
                    username: newUsername,
                    email: u.email,
                    avatarUrl: newAvatarUrl,
                  )
                : u)
            .toList();
        // Kendi profilimizse _auth da güncellensin
        if (userId == _auth.userId) {
          _auth = _auth.copyWith(
            username: newUsername,
            avatarUrl: newAvatarUrl,
          );
        }
      });
    } else if (type == 'presence-updated') {
      final ids = (msg['onlineUserIds'] as List).cast<int>();
      if (!mounted) return;
      setState(() => _onlineUserIds = ids.toSet());
    } else if (type == 'users-updated') {
      final raw = msg['users'] as List;
      final users = raw
          .map((u) => UserProfile.fromJson(u as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() => _allUsers = users);
    } else if (type == 'message-deleted') {
      final messageId = msg['messageId'] as int;
      final channelId = msg['channelId'] as int;
      if (!mounted) return;
      setState(() {
        final list = _messages[channelId];
        if (list != null) {
          list.removeWhere((m) => m.id == messageId);
        }
      });
    } else if (type == 'channels-updated') {
      final raw = msg['channels'] as List;
      final updatedServerId = msg['serverId'] as int?;
      final list = raw
          .map((c) => Channel.fromJson(c as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      // Sadece şu an seçili sunucuya aitse UI'ı güncelle
      if (updatedServerId == null || updatedServerId == _activeServer?.id) {
        setState(() {
          _channels = list;
          if (_selectedChannel != null &&
              !list.any((c) => c.id == _selectedChannel!.id)) {
            _selectedChannel = list.where((c) => !c.isVoice).firstOrNull;
          }
        });
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _deleteMessage(Message message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2F3136),
        title: const Text('Mesajı sil?',
            style: TextStyle(color: Colors.white)),
        content: Text(
          'Bu mesaj kalıcı olarak silinecek:\n\n"${message.content}"',
          style: const TextStyle(color: Colors.white70),
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
      await Api.deleteMessage(_auth.token, message.id);
      // WS broadcast otomatik olarak listemizi temizleyecek
    } on ApiException catch (e) {
      _showSnack('Hata: ${e.message}');
    } catch (e) {
      _showSnack('Bağlantı hatası: $e');
    }
  }

  void _sendMessage() {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty || _selectedChannel == null || !_connected) return;
    if (_selectedChannel!.isVoice) return;
    _ws?.sink.add(jsonEncode({
      'type': 'message',
      'channelId': _selectedChannel!.id,
      'content': text,
    }));
    _msgCtrl.clear();
  }

  Future<void> _joinVoiceChannel(Channel channel) async {
    final granted = await _ensureMicPermission();
    if (!granted) {
      _showSnack('Sesli görüşme için mikrofon izni gerekli');
      return;
    }
    // Backend'e katılma isteği gönder; backend bize "voice-joined" cevabı ile
    // mevcut üyeleri dönecek, sonra VoiceManager.join() çağrılacak.
    _ws?.sink.add(jsonEncode({
      'type': 'voice-join',
      'channelId': channel.id,
    }));
  }

  Future<void> _leaveVoiceChannel() async {
    _ws?.sink.add(jsonEncode({'type': 'voice-leave'}));
    await _voice.leave();
    SoundService().playSelfLeft();
  }

  /// Ekran paylaş butonuna basıldığında çağrılır.
  ///
  /// Davranış:
  /// - Şu an paylaşım YAPILMIYORSA: kaynak seçici aç, seçilen kaynakla başlat.
  /// - Şu an paylaşım YAPILIYORSA: kaynak seçici aç. Kullanıcı:
  ///   * Yeni kaynak seçerse → eski durdurulur, yeni başlatılır
  ///   * "Paylaşımı Durdur" tıklarsa → durdurulur
  ///   * İptal ederse → mevcut paylaşım devam eder
  Future<void> _chooseScreenSource() async {
    final isDesktop = !kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

    if (!isDesktop) {
      try {
        if (_voice.isScreenSharing) {
          await _voice.stopScreenShare();
        } else {
          await _voice.startScreenShare(options: _shareOptions);
        }
      } catch (e) {
        _showErrorDialog('Ekran paylaşımı başarısız', e.toString());
      }
      return;
    }

    String? result;
    try {
      result = await _pickDesktopSource(
        currentlySharing: _voice.isScreenSharing,
      );
    } catch (e) {
      _showErrorDialog('Kaynak listesi alınamadı', e.toString());
      return;
    }

    if (result == null) return;

    if (result == kScreenPickerStop) {
      try {
        await _voice.stopScreenShare();
      } catch (e) {
        _showSnack('Paylaşım durdurulamadı: $e');
      }
      return;
    }

    try {
      if (_voice.isScreenSharing) {
        // Kaynak değişimi: replaceTrack pattern — m-line ve transceiver
        // aynı kalır, SDP değişmez, renegotiate gerekmez → karşı tarafta
        // donma olmaz. stop+start fallback'i hata durumunda kullanılır.
        try {
          await _voice.replaceScreenSource(
            sourceId: result,
            options: _shareOptions,
          );
        } catch (e) {
          debugPrint('replaceScreenSource fail, fallback stop+start: $e');
          await _voice.stopScreenShare(skipRenegotiate: true);
          await Future.delayed(const Duration(milliseconds: 150));
          await _voice.startScreenShare(
              sourceId: result, options: _shareOptions);
        }
      } else {
        await _voice.startScreenShare(
            sourceId: result, options: _shareOptions);
      }
      _showScreenShareStatus();
      // Paylaşım başladıktan sonra uygulamayı tekrar öne getir
      await Future.delayed(const Duration(milliseconds: 300));
      try {
        await windowManager.show();
        await windowManager.focus();
      } catch (_) {/* yoksay */}
    } catch (e, st) {
      debugPrint('Ekran paylaşım hatası: $e\n$st');
      _showErrorDialog('Ekran paylaşımı başarısız', e.toString());
    }
  }

  void _openSettings() {
    showDialog<void>(
      context: context,
      builder: (ctx) => _SettingsDialog(
        token: _auth.token,
        username: _auth.username,
        email: _auth.email,
        avatarUrl: _auth.avatarUrl,
        currentServer: Config.backendHost,
        voice: _voice,
        onLogout: _logout,
        onSaveServer: (newHost) async {
          Config.setHost(newHost);
          await Storage.setServerHost(newHost);
          await Storage.touchServer(newHost);
          if (mounted) {
            _showSnack('Sunucu seçildi. Uygulamayı yeniden başlat.');
          }
        },
        onProfileUpdated: (updated) async {
          await Storage.save(
            token: _auth.token,
            username: updated.username,
            userId: _auth.userId,
          );
          if (!mounted) return;
          setState(() {
            _auth = _auth.copyWith(
              username: updated.username,
              email: updated.email,
              avatarUrl: updated.avatarUrl,
            );
          });
        },
      ),
    );
  }

  Future<void> _switchToServer(ServerInfo server) async {
    if (server.id == _activeServer?.id) return; // zaten aktif
    setState(() {
      _activeServer = server;
      _selectedChannel = null;
      _messages.clear();
      _voiceMembers.clear();
    });
    await Storage.setActiveServerId(server.id);
    // Sesli kanaldaysak ayrıl (farklı sunucuya geçildi)
    if (_voice.inVoice) {
      await _leaveVoiceChannel();
    }
    await _loadChannels();
    await _loadUsers();
  }

  Future<void> _openAddServerDialog() async {
    final result = await showDialog<ServerInfo>(
      context: context,
      builder: (ctx) => _AddServerDialog(token: _auth.token),
    );
    if (result == null) return;
    setState(() => _servers = [..._servers, result]);
    await _switchToServer(result);
  }

  Future<void> _openServerContextMenu(
      Offset position, ServerInfo server) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selected = await showMenu<String>(
      context: context,
      color: const Color(0xFF2F3136),
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(
          value: 'invite',
          child: Row(
            children: [
              Icon(Icons.key, size: 16, color: Colors.white70),
              SizedBox(width: 8),
              Text('Davet Kodunu Göster',
                  style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'settings',
          child: Row(
            children: [
              Icon(Icons.tune, size: 16, color: Colors.white70),
              SizedBox(width: 8),
              Text('Sunucu Ayarları',
                  style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
        if (!server.isOwner)
          const PopupMenuItem(
            value: 'leave',
            child: Row(
              children: [
                Icon(Icons.logout, size: 16, color: Colors.redAccent),
                SizedBox(width: 8),
                Text('Sunucudan Ayrıl',
                    style: TextStyle(color: Colors.redAccent)),
              ],
            ),
          ),
      ],
    );
    if (selected == 'invite') {
      _showInviteCodeDialog(server);
    } else if (selected == 'settings') {
      await _openServerSettings(server);
    } else if (selected == 'leave') {
      await _leaveServer(server);
    }
  }

  Future<void> _openServerSettings(ServerInfo server) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => ServerSettingsDialog(
        token: _auth.token,
        server: server,
      ),
    );
    // Ayarlardan sonra üye/permission değişmiş olabilir; listeyi tazele
    await _loadServers();
  }

  void _showInviteCodeDialog(ServerInfo server) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2F3136),
        title: Text('${server.name} - Davet Kodu',
            style: const TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Bu kodu arkadaşlarınla paylaş, sunucuna katılabilsinler:',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF202225),
                borderRadius: BorderRadius.circular(4),
              ),
              child: SelectableText(
                server.inviteCode,
                style: const TextStyle(
                  color: Color(0xFF5865F2),
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Tamam'),
          ),
        ],
      ),
    );
  }

  Future<void> _leaveServer(ServerInfo server) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2F3136),
        title: Text('"${server.name}" sunucusundan ayrıl?',
            style: const TextStyle(color: Colors.white)),
        content: const Text(
          'Tekrar katılmak için davet kodu gerekecek.',
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
            child: const Text('Ayrıl'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await Api.leaveServer(_auth.token, server.id);
      final updated = _servers.where((s) => s.id != server.id).toList();
      setState(() => _servers = updated);
      if (_activeServer?.id == server.id && updated.isNotEmpty) {
        await _switchToServer(updated.first);
      }
    } catch (e) {
      _showSnack('Hata: $e');
    }
  }

  Future<void> _openCreateChannelDialog(String channelType) async {
    final result = await showDialog<({String name, String type})>(
      context: context,
      builder: (ctx) => _ChannelCreateDialog(initialType: channelType),
    );
    if (result == null) return;
    final activeServer = _activeServer;
    if (activeServer == null) {
      _showSnack('Önce bir sunucu seç');
      return;
    }
    try {
      await Api.createChannel(
          _auth.token, activeServer.id, result.name, result.type);
      // WS broadcast otomatik olarak listeyi güncelleyecek
    } on ApiException catch (e) {
      _showSnack('Hata: ${e.message}');
    } catch (e) {
      _showSnack('Bağlantı hatası: $e');
    }
  }

  Future<void> _openChannelContextMenu(Offset position, Channel channel) async {
    final canManage =
        _activeServer?.hasPermission(Permissions.manageChannels) ?? false;
    if (!canManage) {
      _showSnack('Kanal yönetme yetkin yok');
      return;
    }
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selected = await showMenu<String>(
      context: context,
      color: const Color(0xFF2F3136),
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(
          value: 'rename',
          child: Row(
            children: [
              Icon(Icons.edit, size: 16, color: Colors.white70),
              SizedBox(width: 8),
              Text('Yeniden Adlandır',
                  style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete, size: 16, color: Colors.redAccent),
              SizedBox(width: 8),
              Text('Kanalı Sil',
                  style: TextStyle(color: Colors.redAccent)),
            ],
          ),
        ),
      ],
    );

    if (selected == 'rename') {
      await _renameChannel(channel);
    } else if (selected == 'delete') {
      await _deleteChannel(channel);
    }
  }

  Future<void> _renameChannel(Channel channel) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => _ChannelRenameDialog(channel: channel),
    );
    if (newName == null || newName.trim().isEmpty) return;
    try {
      await Api.renameChannel(_auth.token, channel.id, newName.trim());
    } on ApiException catch (e) {
      _showSnack('Hata: ${e.message}');
    } catch (e) {
      _showSnack('Bağlantı hatası: $e');
    }
  }

  Future<void> _deleteChannel(Channel channel) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2F3136),
        title: Text(
          channel.isVoice
              ? '🔊 ${channel.name} silinsin mi?'
              : '# ${channel.name} silinsin mi?',
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          channel.isVoice
              ? 'Bu sesli kanal silinecek. Şu an içinde olanlar çıkarılacak.'
              : 'Bu metin kanalı ve içindeki tüm mesajlar silinecek. '
                  'Bu işlem geri alınamaz.',
          style: const TextStyle(color: Colors.white70),
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
      await Api.deleteChannel(_auth.token, channel.id);
    } on ApiException catch (e) {
      _showSnack('Hata: ${e.message}');
    } catch (e) {
      _showSnack('Bağlantı hatası: $e');
    }
  }

  void _openMemberVolumeDialog(int userId, String username, String? avatarUrl) {
    showDialog<void>(
      context: context,
      builder: (ctx) => _VolumeDialog(
        username: username,
        avatarUrl: avatarUrl,
        initialVolume: _voice.getPeerVolume(userId),
        onChanged: (v) => _voice.setPeerVolume(userId, v),
      ),
    );
  }

  void _showScreenShareStatus() {
    final audioCount = _voice.screenShareAudioTrackCount;
    if (audioCount > 0) {
      _showSnack(
          'Yayın aktif: görüntü + sistem sesi paylaşılıyor (kendi uygulama sesi hariç)');
    } else {
      _showSnack(
          'Yayın aktif: sadece görüntü paylaşılıyor (sistem sesi yakalanamadı)');
    }
  }

  void _openScreenViewer() {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => _ScreenViewerDialog(
        voice: _voice,
        myUserId: _auth.userId,
        localRenderer: _localScreenRenderer,
        localCameraRenderer: _localCameraRenderer,
        screenRenderers: _screenRenderers,
        cameraRenderers: _cameraRenderers,
        members: _voiceMembers[_voice.currentChannelId] ?? [],
      ),
    );
  }

  Future<String?> _pickDesktopSource({bool currentlySharing = false}) async {
    // Tek bir getSources() çağrısı yap — iki ayrı çağrı native cache'i
    // bozuyor ve "source not found" hatasına neden olabiliyordu.
    final all = await desktopCapturer.getSources(
      types: [SourceType.Screen, SourceType.Window],
    );
    final screens = all.where((s) => s.type == SourceType.Screen).toList();
    final windows = all.where((s) => s.type == SourceType.Window).toList();
    if (!mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (ctx) => _ScreenSourcePicker(
        screens: screens,
        windows: windows,
        isCurrentlySharing: currentlySharing,
        onOpenSettings: _openShareSettings,
      ),
    );
  }

  Future<void> _openShareSettings() async {
    final result = await showDialog<ScreenShareOptions>(
      context: context,
      builder: (ctx) => _ScreenShareSettingsDialog(initial: _shareOptions),
    );
    if (result == null) return;
    setState(() => _shareOptions = result);
    await result.save();
    // Şu an paylaşım yapılıyorsa, yeni ayarlarla yeniden başlat
    if (_voice.isScreenSharing) {
      _showSnack('Ayarlar uygulandı, paylaşım yeniden başlatılıyor...');
    }
  }

  void _showErrorDialog(String title, String message) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2F3136),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: SelectableText(
            message,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Tamam'),
          ),
        ],
      ),
    );
  }

  Future<bool> _ensureMicPermission() async {
    // Windows masaüstünde Permission.microphone destekleniyor; reddedilirse fallback yok
    try {
      final status = await Permission.microphone.request();
      return status.isGranted;
    } catch (_) {
      // permission_handler bazı masaüstü platformlarda atabilir, ama Windows OK.
      // Eğer izin sistemi yoksa true kabul edelim (getUserMedia kendisi soracak)
      return true;
    }
  }

  Future<void> _logout() async {
    await _leaveVoiceChannel();
    await Storage.clear();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }


  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 700;
    return Scaffold(
      backgroundColor: const Color(0xFF36393F),
      drawer: isWide ? null : Drawer(child: _buildSidebar()),
      appBar: AppBar(
        backgroundColor: const Color(0xFF202225),
        foregroundColor: Colors.white,
        title: Row(
          children: [
            Text(
              _selectedChannel == null
                  ? '...'
                  : (_selectedChannel!.isVoice
                      ? '🔊 ${_selectedChannel!.name}'
                      : '# ${_selectedChannel!.name}'),
            ),
            const SizedBox(width: 12),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _connected ? Colors.greenAccent : Colors.redAccent,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              _membersVisible
                  ? Icons.people
                  : Icons.people_outline,
            ),
            tooltip: _membersVisible ? 'Üye listesini gizle' : 'Üye listesini göster',
            onPressed: _toggleMembersPanel,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Ayarlar',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    // Sol: dikey server paneli (Discord stili)
                    SizedBox(width: 72, child: _buildServerPanel()),
                    // Orta sol: kanal sidebar
                    if (isWide) SizedBox(width: 240, child: _buildSidebar()),
                    // Orta: ana içerik
                    Expanded(child: _buildMainArea()),
                    // Sağ: üye listesi (yeterince geniş pencerede + gizli değilse)
                    if (isWide && _membersVisible)
                      SizedBox(width: 220, child: _buildMembersPanel()),
                  ],
                ),
              ),
              if (_voice.inVoice)
                SizedBox(height: 56, child: _buildVoiceStatusBar()),
            ],
          ),
          // Sağ alt köşe: kendi yayınımızın canlı önizlemesi (PIP)
          if (_voice.inVoice &&
              _previewVisible &&
              (_voice.isCameraSharing || _voice.isScreenSharing))
            Positioned(
              right: _previewOffset.dx,
              bottom: (_voice.inVoice ? 56 : 0) + _previewOffset.dy,
              child: _buildLocalPreviewOverlay(),
            ),
        ],
      ),
    );
  }

  Widget _buildLocalPreviewOverlay() {
    final items = <Widget>[];
    if (_voice.isCameraSharing && _localCameraRenderer != null) {
      items.add(_previewTile(
        renderer: _localCameraRenderer!,
        label: 'Kameran',
        icon: Icons.videocam,
        iconColor: Colors.greenAccent,
      ));
    }
    if (_voice.isScreenSharing && _localScreenRenderer != null) {
      items.add(_previewTile(
        renderer: _localScreenRenderer!,
        label: 'Ekranın',
        icon: Icons.tv,
        iconColor: Colors.orangeAccent,
      ));
    }
    if (items.isEmpty) return const SizedBox.shrink();

    return Material(
      color: Colors.transparent,
      elevation: 8,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            _previewOffset = Offset(
              (_previewOffset.dx - details.delta.dx)
                  .clamp(8.0, MediaQuery.of(context).size.width - 250),
              (_previewOffset.dy - details.delta.dy)
                  .clamp(8.0, MediaQuery.of(context).size.height - 250),
            );
          });
        },
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xCC18191C),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white24),
            boxShadow: const [
              BoxShadow(color: Colors.black54, blurRadius: 12),
            ],
          ),
          padding: const EdgeInsets.all(6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Üst bar: başlık + kapat butonu (sürükle ipucu)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.drag_indicator,
                        size: 14, color: Colors.white38),
                    const SizedBox(width: 4),
                    const Text(
                      'Önizleme',
                      style: TextStyle(
                          color: Colors.white60,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: () =>
                          setState(() => _previewVisible = false),
                      child: const Icon(Icons.close,
                          size: 14, color: Colors.white54),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              // Feed thumbnail'leri — yatay sıralı
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: items,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _previewTile({
    required RTCVideoRenderer renderer,
    required String label,
    required IconData icon,
    required Color iconColor,
  }) {
    return GestureDetector(
      onTap: _openScreenViewer,
      child: Container(
        width: 200,
        height: 120,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: iconColor.withValues(alpha: 0.6)),
        ),
        clipBehavior: Clip.hardEdge,
        child: Stack(
          children: [
            Positioned.fill(
              child: RTCVideoView(
                renderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                mirror: label == 'Kameran',
              ),
            ),
            Positioned(
              left: 4,
              top: 4,
              child: Container(
                color: Colors.black54,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 11, color: iconColor),
                    const SizedBox(width: 4),
                    Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMembersPanel() {
    final online = <UserProfile>[];
    final offline = <UserProfile>[];
    for (final u in _allUsers) {
      if (_onlineUserIds.contains(u.id)) {
        online.add(u);
      } else {
        offline.add(u);
      }
    }
    online.sort(
        (a, b) => a.username.toLowerCase().compareTo(b.username.toLowerCase()));
    offline.sort(
        (a, b) => a.username.toLowerCase().compareTo(b.username.toLowerCase()));

    return Container(
      color: const Color(0xFF2F3136),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: const Color(0xFF202225),
            width: double.infinity,
            child: Row(
              children: const [
                Icon(Icons.people, color: Colors.white54, size: 18),
                SizedBox(width: 8),
                Text(
                  'ÜYELER',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                if (online.isNotEmpty) ...[
                  _membersGroupHeader('ÇEVRİMİÇİ', online.length),
                  for (final u in online) _memberTile(u, online: true),
                  const SizedBox(height: 8),
                ],
                if (offline.isNotEmpty) ...[
                  _membersGroupHeader('ÇEVRİMDIŞI', offline.length),
                  for (final u in offline) _memberTile(u, online: false),
                ],
                if (_allUsers.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Henüz kayıtlı üye yok.',
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _membersGroupHeader(String label, int count) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(
          '$label — $count',
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
      );

  Widget _memberTile(UserProfile user, {required bool online}) {
    final isMe = user.id == _auth.userId;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: isMe ? _openProfileDialog : null,
          onSecondaryTapDown: (details) =>
              _openMemberContextMenu(details.globalPosition, user),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Opacity(
              opacity: online ? 1.0 : 0.45,
              child: Row(
                children: [
                  UserAvatar(
                    username: user.username,
                    avatarUrl: user.avatarUrl,
                    radius: 16,
                    online: online,
                    statusBorderColor: const Color(0xFF2F3136),
                    speaking:
                        _voice.inVoice && _voice.isUserSpeaking(user.id),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          user.username,
                          style: TextStyle(
                            color: online ? Colors.white : Colors.white60,
                            fontWeight: online
                                ? FontWeight.w500
                                : FontWeight.normal,
                            fontSize: 14,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  // Rol göstergesi (sahip için)
                  if (user.isOwner)
                    const Tooltip(
                      message: 'Sahip',
                      child: Icon(Icons.star,
                          size: 14, color: Colors.amberAccent),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openMemberContextMenu(
      Offset position, UserProfile user) async {
    final isMe = user.id == _auth.userId;
    final canManageRoles =
        _activeServer?.hasPermission(Permissions.manageRoles) ?? false;
    final targetIsOwner = user.isOwner;

    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final items = <PopupMenuEntry<String>>[];
    if (!isMe) {
      items.add(
        const PopupMenuItem(
          value: 'volume',
          child: Row(
            children: [
              Icon(Icons.volume_up, size: 16, color: Colors.white70),
              SizedBox(width: 8),
              Text('Ses Seviyesi', style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
      );
    }
    if (canManageRoles && !targetIsOwner) {
      items.add(
        const PopupMenuItem(
          value: 'roles',
          child: Row(
            children: [
              Icon(Icons.shield, size: 16, color: Colors.greenAccent),
              SizedBox(width: 8),
              Text('Rolleri Yönet',
                  style: TextStyle(color: Colors.greenAccent)),
            ],
          ),
        ),
      );
    }
    if (items.isEmpty) return;

    final selected = await showMenu<String>(
      context: context,
      color: const Color(0xFF2F3136),
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: items,
    );

    if (selected == 'volume') {
      _openMemberVolumeDialog(user.id, user.username, user.avatarUrl);
    } else if (selected == 'roles') {
      await _openMemberRolesDialog(user);
    }
  }

  Future<void> _openMemberRolesDialog(UserProfile user) async {
    final activeServer = _activeServer;
    if (activeServer == null) return;
    try {
      final roles =
          await Api.getServerRoles(_auth.token, activeServer.id);
      if (!mounted) return;
      final changed = await showDialog<bool>(
        context: context,
        builder: (ctx) => _MemberRolesDialog(
          token: _auth.token,
          serverId: activeServer.id,
          user: user,
          allRoles: roles,
        ),
      );
      if (changed == true) {
        await _loadUsers();
      }
    } catch (e) {
      _showSnack('Roller alınamadı: $e');
    }
  }

  Widget _buildServerPanel() {
    return Container(
      color: const Color(0xFF202225),
      child: Column(
        children: [
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 4),
              children: [
                for (final s in _servers) _buildServerIcon(s),
                _buildAddServerButton(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildServerIcon(ServerInfo server) {
    final isActive = _activeServer?.id == server.id;
    final initials = server.name.isEmpty
        ? '?'
        : server.name
            .trim()
            .split(RegExp(r'\s+'))
            .take(2)
            .map((w) => w.isNotEmpty ? w[0].toUpperCase() : '')
            .join();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          // Sol kenar göstergesi (aktif olunca beyaz çubuk)
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 4,
            height: isActive ? 40 : 8,
            decoration: BoxDecoration(
              color: isActive ? Colors.white : Colors.transparent,
              borderRadius: const BorderRadius.horizontal(
                right: Radius.circular(4),
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: GestureDetector(
                onSecondaryTapDown: (details) =>
                    _openServerContextMenu(details.globalPosition, server),
                child: Tooltip(
                  message: server.name,
                  child: InkWell(
                    onTap: () => _switchToServer(server),
                    customBorder: const CircleBorder(),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: isActive
                            ? const Color(0xFF5865F2)
                            : const Color(0xFF36393F),
                        borderRadius:
                            BorderRadius.circular(isActive ? 16 : 24),
                      ),
                      child: Center(
                        child: Text(
                          initials,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddServerButton() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const SizedBox(width: 4),
          Expanded(
            child: Center(
              child: Tooltip(
                message: 'Yeni sunucu ekle',
                child: InkWell(
                  onTap: _openAddServerDialog,
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: const Color(0xFF36393F),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: const Center(
                      child: Icon(Icons.add,
                          color: Color(0xFF3BA55D), size: 24),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar() {
    final textChannels = _channels.where((c) => !c.isVoice).toList();
    final voiceChannels = _channels.where((c) => c.isVoice).toList();

    return Container(
      color: const Color(0xFF2F3136),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: _activeServer == null
                ? null
                : () => _showInviteCodeDialog(_activeServer!),
            child: Container(
              padding: const EdgeInsets.all(16),
              color: const Color(0xFF202225),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _activeServer?.name ?? 'Sunucu',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(Icons.expand_more,
                      color: Colors.white54, size: 18),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                _sidebarHeaderWithAdd('METİN KANALLARI', 'text'),
                for (final c in textChannels) _textChannelTile(c),
                _sidebarHeaderWithAdd('SESLİ KANALLAR', 'voice'),
                for (final c in voiceChannels) _voiceChannelTile(c),
              ],
            ),
          ),
          _userFooter(),
        ],
      ),
    );
  }

  Widget _sidebarHeaderWithAdd(String text, String channelType) {
    final canManage =
        _activeServer?.hasPermission(Permissions.manageChannels) ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
          ),
          // Sadece admin/owner kanal oluşturabilir
          if (canManage)
            InkWell(
              onTap: () => _openCreateChannelDialog(channelType),
              borderRadius: BorderRadius.circular(4),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(
                  Icons.add,
                  size: 16,
                  color: Colors.white54,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _textChannelTile(Channel c) {
    final selected = c.id == _selectedChannel?.id;
    return GestureDetector(
      onSecondaryTapDown: (details) =>
          _openChannelContextMenu(details.globalPosition, c),
      child: ListTile(
        dense: true,
        selected: selected,
        selectedTileColor: const Color(0xFF42464D),
        leading: const Text('#',
            style: TextStyle(color: Colors.white54, fontSize: 18)),
        title: Text(
          c.name,
          style: TextStyle(color: selected ? Colors.white : Colors.white70),
        ),
        onTap: () {
          setState(() => _selectedChannel = c);
          if (!_messages.containsKey(c.id)) _loadMessages(c.id);
          if (Navigator.of(context).canPop()) Navigator.of(context).pop();
        },
      ),
    );
  }

  Widget _voiceChannelTile(Channel c) {
    final iAmHere = _voice.currentChannelId == c.id;
    final members = _voiceMembers[c.id] ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onSecondaryTapDown: (details) =>
              _openChannelContextMenu(details.globalPosition, c),
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.volume_up,
                color: Colors.white54, size: 18),
            title: Text(c.name,
                style: TextStyle(
                    color: iAmHere ? Colors.white : Colors.white70)),
            trailing: iAmHere
                ? IconButton(
                    icon: const Icon(Icons.call_end,
                        color: Colors.redAccent, size: 20),
                    tooltip: 'Ayrıl',
                    onPressed: _leaveVoiceChannel,
                  )
                : IconButton(
                    icon: const Icon(Icons.call,
                        color: Colors.greenAccent, size: 20),
                    tooltip: 'Katıl',
                    onPressed: () => _joinVoiceChannel(c),
                  ),
            onTap: () {
              if (!iAmHere) _joinVoiceChannel(c);
            },
          ),
        ),
        // Kanaldaki üyeler — sağ tık ile ses ayarı popup'ı
        ...members.map((m) {
          final isMe = m.userId == _auth.userId;
          return GestureDetector(
            onSecondaryTapDown: isMe
                ? null
                : (_) => _openMemberVolumeDialog(
                    m.userId, m.username, m.avatarUrl),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.only(left: 36, right: 8, bottom: 2),
              child: Row(
                children: [
                  UserAvatar(
                    username: m.username,
                    avatarUrl: m.avatarUrl,
                    radius: 10,
                    speaking:
                        iAmHere && _voice.isUserSpeaking(m.userId),
                  ),
                  // Yayın yapan üyenin yanında "Görüntüle" butonu (avatar sağında)
                  if ((m.screenSharing || m.cameraSharing) && iAmHere && !isMe)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          iconSize: 14,
                          tooltip:
                              '${m.username} yayınını izle (${m.screenSharing ? "ekran" : ""}${m.screenSharing && m.cameraSharing ? "+" : ""}${m.cameraSharing ? "kamera" : ""})',
                          icon: const Icon(Icons.visibility,
                              color: Color(0xFF00AFF4)),
                          onPressed: _openScreenViewer,
                        ),
                      ),
                    )
                  else if (m.screenSharing || m.cameraSharing)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Icon(
                        m.cameraSharing && !m.screenSharing
                            ? Icons.videocam
                            : Icons.tv,
                        size: 12,
                        color: m.cameraSharing
                            ? Colors.greenAccent
                            : Colors.orangeAccent,
                      ),
                    ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      m.username,
                      style: const TextStyle(
                          color: Colors.white60, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Kendi mute durumu
                  if (isMe && _voice.isMuted)
                    const Icon(Icons.mic_off,
                        size: 13, color: Colors.redAccent),
                  // Diğer kullanıcılar için: ses seviyesi 100% değilse göster
                  if (!isMe && _voice.getPeerVolume(m.userId) != 1.0)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text(
                        '${(_voice.getPeerVolume(m.userId) * 100).round()}%',
                        style: TextStyle(
                          color: _voice.getPeerVolume(m.userId) == 0
                              ? Colors.redAccent
                              : Colors.amberAccent,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _userFooter() => Material(
        color: const Color(0xFF292B2F),
        child: InkWell(
          onTap: _openProfileDialog,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                UserAvatar(
                  username: _auth.username,
                  avatarUrl: _auth.avatarUrl,
                  radius: 18,
                  speaking:
                      _voice.inVoice && _voice.isUserSpeaking(_auth.userId),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _auth.username,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (_auth.email != null)
                        Text(
                          _auth.email!,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const Icon(Icons.edit, color: Colors.white54, size: 16),
              ],
            ),
          ),
        ),
      );

  Future<void> _openProfileDialog() async {
    // Artık profil düzenleme settings dialog'unun Hesap sekmesinde
    _openSettings();
  }

  Widget _buildVoiceStatusBar() {
    final channel = _channels.firstWhere(
      (c) => c.id == _voice.currentChannelId,
      orElse: () => Channel(id: 0, name: '?', type: 'voice'),
    );
    final ping = _lastPingMs;
    final IconData pingIcon;
    final Color pingColor;
    if (ping == null) {
      pingIcon = Icons.signal_cellular_connected_no_internet_0_bar;
      pingColor = Colors.white54;
    } else if (ping < 100) {
      pingIcon = Icons.signal_cellular_4_bar;
      pingColor = Colors.greenAccent;
    } else if (ping < 200) {
      pingIcon = Icons.signal_cellular_alt_2_bar;
      pingColor = Colors.lightGreenAccent;
    } else if (ping < 400) {
      pingIcon = Icons.signal_cellular_alt_1_bar;
      pingColor = Colors.amberAccent;
    } else {
      pingIcon = Icons.signal_cellular_0_bar;
      pingColor = Colors.redAccent;
    }
    final pingTooltip =
        ping == null ? 'Ping ölçülüyor...' : 'Ping: $ping ms';

    return Container(
      color: const Color(0xFF1F4D2E),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Tooltip(
            message: pingTooltip,
            child: Icon(pingIcon, color: pingColor, size: 18),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Ses Bağlı',
                    style: TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 11,
                        fontWeight: FontWeight.bold)),
                Text(
                  '🔊 ${channel.name}',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // Kanal kontrolleri (kamera, paylaş, ayrıl)
          IconButton(
            icon: Icon(
              _voice.isCameraSharing ? Icons.videocam : Icons.videocam_off,
              color: _voice.isCameraSharing
                  ? Colors.greenAccent
                  : Colors.white,
            ),
            tooltip: _voice.isCameraSharing
                ? 'Kamerayı kapat'
                : 'Kamerayı aç',
            onPressed: _toggleCamera,
          ),
          IconButton(
            icon: Icon(
              Icons.screen_share,
              color: _voice.isScreenSharing
                  ? Colors.orangeAccent
                  : Colors.white,
            ),
            tooltip: _voice.isScreenSharing
                ? 'Paylaşım menüsü (değiştir / durdur)'
                : 'Ekran paylaş',
            onPressed: _chooseScreenSource,
          ),
          // Önizleme overlay aç/kapat (sadece bir paylaşım aktifse)
          if (_voice.isCameraSharing || _voice.isScreenSharing)
            IconButton(
              icon: Icon(
                _previewVisible
                    ? Icons.picture_in_picture_alt
                    : Icons.picture_in_picture,
                color: _previewVisible ? Colors.cyanAccent : Colors.white,
              ),
              tooltip: _previewVisible
                  ? 'Önizlemeyi gizle'
                  : 'Önizlemeyi göster',
              onPressed: () =>
                  setState(() => _previewVisible = !_previewVisible),
            ),
          IconButton(
            icon: const Icon(Icons.call_end, color: Colors.redAccent),
            tooltip: 'Ayrıl',
            onPressed: _leaveVoiceChannel,
          ),
          const SizedBox(width: 8),
          // Kişisel kontroller — Discord düzeni: mute / deafen / settings
          IconButton(
            icon: Icon(
              _voice.isMuted ? Icons.mic_off : Icons.mic,
              color: _voice.isMuted ? Colors.redAccent : Colors.white,
            ),
            tooltip: _voice.isMuted ? 'Sesi aç' : 'Sustur',
            onPressed: _voice.toggleMute,
          ),
          IconButton(
            icon: Icon(
              _voice.isDeafened ? Icons.headset_off : Icons.headset,
              color:
                  _voice.isDeafened ? Colors.redAccent : Colors.white,
            ),
            tooltip:
                _voice.isDeafened ? 'Sağırlığı kapat' : 'Kendini sağırlaştır',
            onPressed: _voice.toggleDeafen,
          ),
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white),
            tooltip: 'Ayarlar',
            onPressed: _openSettings,
          ),
        ],
      ),
    );
  }

  Widget _buildMainArea() {
    if (_selectedChannel == null || _selectedChannel!.isVoice) {
      return const Center(
        child: Text('Bir metin kanalı seç',
            style: TextStyle(color: Colors.white54)),
      );
    }
    return _buildTextChannelView();
  }


  Widget _buildTextChannelView() {
    final channelId = _selectedChannel!.id;
    final msgs = _messages[channelId] ?? [];
    return Column(
      children: [
        if (_wsError != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            color: Colors.red.shade900,
            child: Text('WebSocket hatası: $_wsError',
                style: const TextStyle(color: Colors.white)),
          ),
        Expanded(
          child: msgs.isEmpty
              ? const Center(
                  child: Text('Henüz mesaj yok. İlk yazan sen ol!',
                      style: TextStyle(color: Colors.white54)),
                )
              : ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.all(12),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) {
                    final m = msgs[i];
                    final isOwn = m.userId == _auth.userId;
                    final canManage = _activeServer
                            ?.hasPermission(Permissions.manageMessages) ??
                        false;
                    return _MessageBubble(
                      msg: m,
                      canDelete: isOwn || canManage,
                      onDelete: () => _deleteMessage(m),
                    );
                  },
                ),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          color: const Color(0xFF40444B),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _msgCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: '#${_selectedChannel!.name} kanalına mesaj yaz',
                    hintStyle: const TextStyle(color: Colors.white54),
                    filled: true,
                    fillColor: const Color(0xFF40444B),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _connected ? _sendMessage : null,
                icon: const Icon(Icons.send, color: Color(0xFF5865F2)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final Message msg;
  final bool canDelete;
  final VoidCallback? onDelete;
  const _MessageBubble({
    required this.msg,
    this.canDelete = false,
    this.onDelete,
  });

  Future<void> _showContextMenu(BuildContext context, Offset pos) async {
    if (!canDelete) return;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selected = await showMenu<String>(
      context: context,
      color: const Color(0xFF2F3136),
      position: RelativeRect.fromRect(
        Rect.fromLTWH(pos.dx, pos.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete, size: 16, color: Colors.redAccent),
              SizedBox(width: 8),
              Text('Mesajı Sil',
                  style: TextStyle(color: Colors.redAccent)),
            ],
          ),
        ),
      ],
    );
    if (selected == 'delete' && onDelete != null) {
      onDelete!();
    }
  }

  @override
  Widget build(BuildContext context) {
    final time = DateFormat('HH:mm').format(
      DateTime.fromMillisecondsSinceEpoch(msg.createdAt),
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (d) => _showContextMenu(context, d.globalPosition),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            UserAvatar(
              username: msg.username,
              avatarUrl: msg.avatarUrl,
              radius: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(msg.username,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(width: 8),
                      Text(time,
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(msg.content,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 15)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}


class _MemberRolesDialog extends StatefulWidget {
  final String token;
  final int serverId;
  final UserProfile user;
  final List<Role> allRoles;
  const _MemberRolesDialog({
    required this.token,
    required this.serverId,
    required this.user,
    required this.allRoles,
  });

  @override
  State<_MemberRolesDialog> createState() => _MemberRolesDialogState();
}

class _MemberRolesDialogState extends State<_MemberRolesDialog> {
  late Set<int> _assignedIds;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _assignedIds = widget.user.roleIds.toSet();
  }

  Color _parseHex(String h) {
    final s = h.replaceAll('#', '');
    if (s.length != 6) return const Color(0xFF99AAB5);
    return Color(int.parse('FF$s', radix: 16));
  }

  Future<void> _toggle(Role role, bool now) async {
    if (role.isDefault) return; // @everyone elle değiştirilmez
    setState(() => _busy = true);
    try {
      if (now) {
        await Api.assignRole(
          widget.token,
          serverId: widget.serverId,
          userId: widget.user.id,
          roleId: role.id,
        );
        _assignedIds.add(role.id);
      } else {
        await Api.unassignRole(
          widget.token,
          serverId: widget.serverId,
          userId: widget.user.id,
          roleId: role.id,
        );
        _assignedIds.remove(role.id);
      }
      setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Hata: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rolesSorted = [...widget.allRoles]
      ..sort((a, b) {
        if (a.isDefault && !b.isDefault) return 1;
        if (!a.isDefault && b.isDefault) return -1;
        return b.position.compareTo(a.position);
      });
    return Dialog(
      backgroundColor: const Color(0xFF2F3136),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  UserAvatar(
                    username: widget.user.username,
                    avatarUrl: widget.user.avatarUrl,
                    radius: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.user.username,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold)),
                        const Text('Rolleri Yönet',
                            style: TextStyle(
                                color: Colors.white54, fontSize: 12)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => Navigator.of(context).pop(true),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  itemCount: rolesSorted.length,
                  itemBuilder: (_, i) {
                    final r = rolesSorted[i];
                    final assigned = _assignedIds.contains(r.id);
                    return ListTile(
                      dense: true,
                      leading: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: _parseHex(r.color),
                          shape: BoxShape.circle,
                        ),
                      ),
                      title: Text(
                        r.name,
                        style: TextStyle(
                            color:
                                r.isDefault ? Colors.white38 : Colors.white),
                      ),
                      subtitle: r.isDefault
                          ? const Text('Otomatik',
                              style: TextStyle(
                                  color: Colors.white38, fontSize: 11))
                          : null,
                      trailing: r.isDefault
                          ? const Icon(Icons.lock,
                              size: 14, color: Colors.white38)
                          : Switch(
                              value: assigned,
                              activeThumbColor: const Color(0xFF5865F2),
                              onChanged: _busy
                                  ? null
                                  : (v) => _toggle(r, v),
                            ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddServerDialog extends StatefulWidget {
  final String token;
  const _AddServerDialog({required this.token});

  @override
  State<_AddServerDialog> createState() => _AddServerDialogState();
}

class _AddServerDialogState extends State<_AddServerDialog> {
  int _tab = 0; // 0 = oluştur, 1 = katıl
  final _nameCtrl = TextEditingController();
  final _inviteCtrl = TextEditingController();
  String? _error;
  bool _loading = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _inviteCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      ServerInfo result;
      if (_tab == 0) {
        final name = _nameCtrl.text.trim();
        if (name.isEmpty) {
          setState(() => _error = 'Sunucu adı boş olamaz');
          return;
        }
        result = await Api.createServer(widget.token, name);
      } else {
        final code = _inviteCtrl.text.trim();
        if (code.isEmpty) {
          setState(() => _error = 'Davet kodu boş olamaz');
          return;
        }
        result = await Api.joinServer(widget.token, code);
      }
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Hata: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF2F3136),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.dns,
                      color: Color(0xFF5865F2), size: 22),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Sunucu Ekle',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _tabButton('Yeni Oluştur', 0),
                  const SizedBox(width: 8),
                  _tabButton('Davet Kodu', 1),
                ],
              ),
              const SizedBox(height: 16),
              if (_tab == 0) ...[
                const Text('SUNUCU ADI',
                    style: TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1)),
                const SizedBox(height: 6),
                TextField(
                  controller: _nameCtrl,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: _input('örn: Arkadaşların Sunucusu'),
                  onSubmitted: (_) => _submit(),
                ),
              ] else ...[
                const Text('DAVET KODU',
                    style: TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1)),
                const SizedBox(height: 6),
                TextField(
                  controller: _inviteCtrl,
                  autofocus: true,
                  style: const TextStyle(
                      color: Colors.white, letterSpacing: 1.5),
                  decoration: _input('örn: a1b2c3d4'),
                  onSubmitted: (_) => _submit(),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed:
                        _loading ? null : () => Navigator.of(context).pop(),
                    child: const Text('İptal',
                        style: TextStyle(color: Colors.white70)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF5865F2)),
                    onPressed: _loading ? null : _submit,
                    child: _loading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : Text(_tab == 0 ? 'Oluştur' : 'Katıl'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tabButton(String text, int idx) {
    final selected = _tab == idx;
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor:
            selected ? const Color(0xFF5865F2) : const Color(0xFF40444B),
      ),
      onPressed: () => setState(() => _tab = idx),
      child: Text(text),
    );
  }

  InputDecoration _input(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38),
        filled: true,
        fillColor: const Color(0xFF202225),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide.none,
        ),
      );
}

class _ChannelCreateDialog extends StatefulWidget {
  final String initialType;
  const _ChannelCreateDialog({required this.initialType});

  @override
  State<_ChannelCreateDialog> createState() => _ChannelCreateDialogState();
}

class _ChannelCreateDialogState extends State<_ChannelCreateDialog> {
  late String _type;
  final _nameCtrl = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _type = widget.initialType;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Kanal adı boş olamaz');
      return;
    }
    if (name.length > 50) {
      setState(() => _error = 'En fazla 50 karakter');
      return;
    }
    Navigator.of(context).pop((name: name, type: _type));
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF2F3136),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.add_box,
                      color: Color(0xFF5865F2), size: 22),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Kanal oluştur',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text('KANAL TİPİ',
                  style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1)),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: _TypeRadio(
                      icon: Icons.tag,
                      label: 'Metin Kanalı',
                      selected: _type == 'text',
                      onTap: () => setState(() => _type = 'text'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _TypeRadio(
                      icon: Icons.volume_up,
                      label: 'Sesli Kanal',
                      selected: _type == 'voice',
                      onTap: () => setState(() => _type = 'voice'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('KANAL ADI',
                  style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1)),
              const SizedBox(height: 6),
              TextField(
                controller: _nameCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  prefixText: _type == 'text' ? '# ' : '🔊 ',
                  prefixStyle: const TextStyle(color: Colors.white54),
                  hintText: _type == 'text' ? 'yeni-kanal' : 'Yeni Oda',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: const Color(0xFF202225),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: (_) => _submit(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!,
                    style: const TextStyle(color: Colors.redAccent)),
              ],
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('İptal',
                        style: TextStyle(color: Colors.white70)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF5865F2),
                    ),
                    onPressed: _submit,
                    child: const Text('Oluştur'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TypeRadio extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _TypeRadio({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF5865F2).withValues(alpha: 0.2)
              : const Color(0xFF202225),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color:
                selected ? const Color(0xFF5865F2) : Colors.transparent,
            width: 2,
          ),
        ),
        child: Row(
          children: [
            Icon(icon,
                color:
                    selected ? const Color(0xFF5865F2) : Colors.white54,
                size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.white : Colors.white70,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChannelRenameDialog extends StatefulWidget {
  final Channel channel;
  const _ChannelRenameDialog({required this.channel});

  @override
  State<_ChannelRenameDialog> createState() => _ChannelRenameDialogState();
}

class _ChannelRenameDialogState extends State<_ChannelRenameDialog> {
  late final TextEditingController _ctrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.channel.name);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _ctrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Boş olamaz');
      return;
    }
    if (name == widget.channel.name) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF2F3136),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.edit, color: Colors.white, size: 22),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Kanalı Yeniden Adlandır',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text('YENİ AD',
                  style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1)),
              const SizedBox(height: 6),
              TextField(
                controller: _ctrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  prefixText: widget.channel.isVoice ? '🔊 ' : '# ',
                  prefixStyle: const TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: const Color(0xFF202225),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: (_) => _submit(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!,
                    style: const TextStyle(color: Colors.redAccent)),
              ],
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('İptal',
                        style: TextStyle(color: Colors.white70)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF5865F2),
                    ),
                    onPressed: _submit,
                    child: const Text('Kaydet'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScreenShareSettingsDialog extends StatefulWidget {
  final ScreenShareOptions initial;
  const _ScreenShareSettingsDialog({required this.initial});

  @override
  State<_ScreenShareSettingsDialog> createState() =>
      _ScreenShareSettingsDialogState();
}

class _ScreenShareSettingsDialogState
    extends State<_ScreenShareSettingsDialog> {
  late int _width;
  late int _height;
  late int _frameRate;
  late double _bitrateKbps;

  @override
  void initState() {
    super.initState();
    _width = widget.initial.width;
    _height = widget.initial.height;
    _frameRate = widget.initial.frameRate;
    _bitrateKbps = widget.initial.maxBitrateKbps.toDouble();
  }

  String _formatBitrate(double kbps) {
    if (kbps >= 1000) {
      return '${(kbps / 1000).toStringAsFixed(1)} Mbps';
    }
    return '${kbps.round()} Kbps';
  }

  @override
  Widget build(BuildContext context) {
    final selectedResolution = ScreenShareOptions.resolutions.firstWhere(
      (r) => r.width == _width && r.height == _height,
      orElse: () => ScreenShareOptions.resolutions[1],
    );

    return Dialog(
      backgroundColor: const Color(0xFF2F3136),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Başlık
              Row(
                children: [
                  const Icon(Icons.tune, color: Colors.white, size: 22),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Yayın Ayarları',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Çözünürlük
              _label('ÇÖZÜNÜRLÜK'),
              const SizedBox(height: 6),
              DropdownButtonFormField<({int width, int height, String label})>(
                initialValue: selectedResolution,
                decoration: _fieldDecoration(),
                dropdownColor: const Color(0xFF202225),
                style: const TextStyle(color: Colors.white),
                items: ScreenShareOptions.resolutions
                    .map((r) => DropdownMenuItem(
                          value: r,
                          child: Text('${r.label}  (${r.width}×${r.height})'),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  setState(() {
                    _width = v.width;
                    _height = v.height;
                  });
                },
              ),
              const SizedBox(height: 14),

              // FPS
              _label('KARE HIZI (FPS)'),
              const SizedBox(height: 6),
              DropdownButtonFormField<int>(
                initialValue: _frameRate,
                decoration: _fieldDecoration(),
                dropdownColor: const Color(0xFF202225),
                style: const TextStyle(color: Colors.white),
                items: ScreenShareOptions.frameRates
                    .map((f) => DropdownMenuItem(
                          value: f,
                          child: Text('$f fps'),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _frameRate = v);
                },
              ),
              const SizedBox(height: 14),

              // Bitrate
              Row(
                children: [
                  _label('BITRATE'),
                  const Spacer(),
                  Text(
                    _formatBitrate(_bitrateKbps),
                    style: const TextStyle(
                      color: Color(0xFF5865F2),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Slider(
                value: _bitrateKbps,
                min: ScreenShareOptions.minBitrateKbps.toDouble(),
                max: ScreenShareOptions.maxBitrateKbpsLimit.toDouble(),
                divisions: 39, // 500 Kbps adımlar
                label: _formatBitrate(_bitrateKbps),
                onChanged: (v) => setState(() => _bitrateKbps = v),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _formatBitrate(
                        ScreenShareOptions.minBitrateKbps.toDouble()),
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 11),
                  ),
                  Text(
                    _formatBitrate(
                        ScreenShareOptions.maxBitrateKbpsLimit.toDouble()),
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Bilgi notu
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF202225),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: const [
                    Icon(Icons.info_outline,
                        color: Colors.white38, size: 16),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Sistem sesi otomatik yakalanır (Discord clone\'un '
                        'kendi çıkışı hariç). Yüksek çözünürlük ve FPS daha '
                        'fazla bant genişliği ve CPU kullanır.',
                        style: TextStyle(
                            color: Colors.white60, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Aksiyonlar
              Row(
                children: [
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white70,
                    ),
                    onPressed: () {
                      setState(() {
                        _width = ScreenShareOptions.defaults.width;
                        _height = ScreenShareOptions.defaults.height;
                        _frameRate = ScreenShareOptions.defaults.frameRate;
                        _bitrateKbps = ScreenShareOptions
                            .defaults.maxBitrateKbps
                            .toDouble();
                      });
                    },
                    child: const Text('Varsayılana Dön'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('İptal',
                        style: TextStyle(color: Colors.white70)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF5865F2),
                    ),
                    onPressed: () {
                      Navigator.of(context).pop(
                        ScreenShareOptions(
                          width: _width,
                          height: _height,
                          frameRate: _frameRate,
                          maxBitrateKbps: _bitrateKbps.round(),
                        ),
                      );
                    },
                    child: const Text('Kaydet'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Text(
        text,
        style: const TextStyle(
          color: Colors.white54,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      );

  InputDecoration _fieldDecoration() => InputDecoration(
        isDense: true,
        filled: true,
        fillColor: const Color(0xFF202225),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide.none,
        ),
      );
}

class _VolumeDialog extends StatefulWidget {
  final String username;
  final String? avatarUrl;
  final double initialVolume;
  final ValueChanged<double> onChanged;

  const _VolumeDialog({
    required this.username,
    required this.avatarUrl,
    required this.initialVolume,
    required this.onChanged,
  });

  @override
  State<_VolumeDialog> createState() => _VolumeDialogState();
}

class _VolumeDialogState extends State<_VolumeDialog> {
  late double _volume;

  @override
  void initState() {
    super.initState();
    _volume = widget.initialVolume.clamp(0.0, 2.0).toDouble();
  }

  void _set(double v) {
    setState(() => _volume = v.clamp(0.0, 2.0).toDouble());
    widget.onChanged(_volume);
  }

  @override
  Widget build(BuildContext context) {
    final percent = (_volume * 100).round();
    final isLoud = _volume > 1.0;
    return Dialog(
      backgroundColor: const Color(0xFF2F3136),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Başlık: kullanıcı kartı
              Row(
                children: [
                  UserAvatar(
                    username: widget.username,
                    avatarUrl: widget.avatarUrl,
                    radius: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.username,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Text(
                          'Kullanıcı sesi',
                          style: TextStyle(
                              color: Colors.white54, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Yüzdelik gösterge
              Center(
                child: Text(
                  '$percent%',
                  style: TextStyle(
                    color: _volume == 0
                        ? Colors.redAccent
                        : (isLoud ? Colors.orangeAccent : Colors.white),
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              // Slider 0-200
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: isLoud
                      ? Colors.orangeAccent
                      : const Color(0xFF5865F2),
                  inactiveTrackColor: Colors.white24,
                  thumbColor: Colors.white,
                  overlayColor: const Color(0x335865F2),
                  valueIndicatorColor: const Color(0xFF5865F2),
                ),
                child: Slider(
                  value: _volume,
                  min: 0.0,
                  max: 2.0,
                  divisions: 200,
                  label: '$percent%',
                  onChanged: _set,
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: const [
                  Text('0%',
                      style: TextStyle(color: Colors.white38, fontSize: 11)),
                  Text('100%',
                      style: TextStyle(color: Colors.white38, fontSize: 11)),
                  Text('200%',
                      style: TextStyle(color: Colors.white38, fontSize: 11)),
                ],
              ),
              const SizedBox(height: 16),
              // Hızlı düğmeler
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white24),
                      ),
                      icon: const Icon(Icons.volume_off, size: 16),
                      label: const Text('Sustur'),
                      onPressed: () => _set(0.0),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white24),
                      ),
                      icon: const Icon(Icons.restart_alt, size: 16),
                      label: const Text('Sıfırla'),
                      onPressed: () => _set(1.0),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.orangeAccent,
                        side: const BorderSide(color: Colors.orangeAccent),
                      ),
                      icon: const Icon(Icons.volume_up, size: 16),
                      label: const Text('Maks'),
                      onPressed: () => _set(2.0),
                    ),
                  ),
                ],
              ),
              if (isLoud) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(8),
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
                          'Bazı sistemler 100%\'ün üzerini desteklemeyebilir.',
                          style: TextStyle(
                              color: Colors.orangeAccent, fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsDialog extends StatefulWidget {
  final String token;
  final String username;
  final String? email;
  final String? avatarUrl;
  final String currentServer;
  final VoiceManager voice;
  final VoidCallback onLogout;
  final Future<void> Function(String) onSaveServer;
  final void Function(UserProfile) onProfileUpdated;

  const _SettingsDialog({
    required this.token,
    required this.username,
    required this.email,
    required this.avatarUrl,
    required this.currentServer,
    required this.voice,
    required this.onLogout,
    required this.onSaveServer,
    required this.onProfileUpdated,
  });

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  int _tab = 0; // 0=Hesap, 1=Ses, 2=Kamera

  // Hesap sekmesi state (profil düzenleme)
  late final TextEditingController _usernameCtrl;
  late final TextEditingController _emailCtrl;
  final _currentPasswordCtrl = TextEditingController();
  final _newPasswordCtrl = TextEditingController();
  bool _profileLoading = false;
  bool _avatarUploading = false;
  bool _showPasswordSection = false;
  String? _profileError;
  String? _profileSuccess;
  late String? _avatarUrl;

  // Ses sekmesi state
  List<MediaDeviceInfo> _audioInputs = [];
  List<MediaDeviceInfo> _audioOutputs = [];
  String? _selectedInputId;
  String? _selectedOutputId;
  bool _loadingDevices = true;
  String? _audioError;

  // Kamera sekmesi state
  List<MediaDeviceInfo> _videoInputs = [];
  String? _selectedCameraId;
  int _selectedCameraWidth = 1280;
  int _selectedCameraFps = 30;
  bool _loadingCameras = false;
  bool _camerasLoaded = false;
  String? _cameraError;
  // Sekme önizleme stream'i (sesli kanalda aktif kamera yoksa geçici stream)
  MediaStream? _previewStream;
  RTCVideoRenderer? _previewRenderer;
  bool _previewBusy = false;
  // Bu stream'i biz mi oluşturduk (true)? veya VoiceManager'a mı ait (false)?
  bool _previewIsOwned = false;

  @override
  void initState() {
    super.initState();
    _usernameCtrl = TextEditingController(text: widget.username);
    _emailCtrl = TextEditingController(text: widget.email ?? '');
    _avatarUrl = widget.avatarUrl;
    _selectedInputId = widget.voice.preferredAudioInputId;
    _selectedOutputId = widget.voice.preferredAudioOutputId;
    _selectedCameraId = widget.voice.preferredCameraDeviceId;
    _selectedCameraWidth = widget.voice.preferredCameraWidth;
    _selectedCameraFps = widget.voice.preferredCameraFps;
    _loadAudioDevices();
  }

  Future<void> _loadAudioDevices() async {
    try {
      // Mikrofon izni iste (cihaz adları için gerekli)
      try {
        final s = await navigator.mediaDevices
            .getUserMedia({'audio': true, 'video': false});
        // İzin için açtık, hemen kapat
        for (final t in s.getTracks()) {
          t.stop();
        }
      } catch (_) {}
      final devices = await navigator.mediaDevices.enumerateDevices();
      if (!mounted) return;
      setState(() {
        _audioInputs =
            devices.where((d) => d.kind == 'audioinput').toList();
        _audioOutputs =
            devices.where((d) => d.kind == 'audiooutput').toList();
        _loadingDevices = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _audioError = '$e';
        _loadingDevices = false;
      });
    }
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _emailCtrl.dispose();
    _currentPasswordCtrl.dispose();
    _newPasswordCtrl.dispose();
    _disposePreview();
    super.dispose();
  }

  Future<void> _disposePreview() async {
    final r = _previewRenderer;
    _previewRenderer = null;
    if (r != null) {
      await r.dispose();
    }
    if (_previewIsOwned && _previewStream != null) {
      for (final t in _previewStream!.getTracks()) {
        try {
          await t.stop();
        } catch (_) {}
      }
      try {
        await _previewStream!.dispose();
      } catch (_) {}
    }
    _previewStream = null;
    _previewIsOwned = false;
  }

  Future<void> _pickAndUploadAvatar() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      setState(() => _profileError = 'Dosya okunamadı');
      return;
    }
    if (bytes.length > 5 * 1024 * 1024) {
      setState(() => _profileError = 'Maksimum 5 MB');
      return;
    }
    setState(() {
      _avatarUploading = true;
      _profileError = null;
      _profileSuccess = null;
    });
    try {
      final updated = await Api.uploadAvatar(
        widget.token,
        bytes: bytes,
        filename: file.name,
      );
      if (!mounted) return;
      setState(() => _avatarUrl = updated.avatarUrl);
      widget.onProfileUpdated(updated);
    } on ApiException catch (e) {
      if (mounted) setState(() => _profileError = e.message);
    } catch (e) {
      if (mounted) setState(() => _profileError = 'Yükleme hatası: $e');
    } finally {
      if (mounted) setState(() => _avatarUploading = false);
    }
  }

  Future<void> _removeAvatar() async {
    setState(() {
      _avatarUploading = true;
      _profileError = null;
      _profileSuccess = null;
    });
    try {
      final updated = await Api.removeAvatar(widget.token);
      if (!mounted) return;
      setState(() => _avatarUrl = null);
      widget.onProfileUpdated(updated);
    } on ApiException catch (e) {
      if (mounted) setState(() => _profileError = e.message);
    } catch (e) {
      if (mounted) setState(() => _profileError = 'Silme hatası: $e');
    } finally {
      if (mounted) setState(() => _avatarUploading = false);
    }
  }

  Future<void> _saveProfile() async {
    final username = _usernameCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    final newPwd = _newPasswordCtrl.text;
    final currentPwd = _currentPasswordCtrl.text;

    if (newPwd.isNotEmpty && currentPwd.isEmpty) {
      setState(() => _profileError = 'Şifre değiştirmek için mevcut şifreni gir');
      return;
    }
    final hasChanges = username != widget.username ||
        email != (widget.email ?? '') ||
        newPwd.isNotEmpty;
    if (!hasChanges) {
      setState(() => _profileSuccess = 'Değişiklik yok');
      return;
    }

    setState(() {
      _profileLoading = true;
      _profileError = null;
      _profileSuccess = null;
    });
    try {
      final result = await Api.updateProfile(
        widget.token,
        username: username != widget.username ? username : null,
        email: email != (widget.email ?? '') ? email : null,
        password: newPwd.isNotEmpty ? newPwd : null,
        currentPassword: currentPwd.isNotEmpty ? currentPwd : null,
      );
      if (!mounted) return;
      widget.onProfileUpdated(result);
      setState(() {
        _profileSuccess = 'Profil güncellendi';
        _currentPasswordCtrl.clear();
        _newPasswordCtrl.clear();
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _profileError = e.message);
    } catch (e) {
      if (mounted) setState(() => _profileError = 'Bağlantı hatası: $e');
    } finally {
      if (mounted) setState(() => _profileLoading = false);
    }
  }

  Future<void> _applyInput(String? deviceId) async {
    if (deviceId == null) return;
    setState(() => _selectedInputId = deviceId);
    try {
      await widget.voice.selectAudioInput(deviceId);
      await Storage.setAudioInputId(deviceId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Mikrofon hatası: $e')));
      }
    }
  }

  Future<void> _applyOutput(String? deviceId) async {
    if (deviceId == null) return;
    setState(() => _selectedOutputId = deviceId);
    try {
      await widget.voice.selectAudioOutput(deviceId);
      await Storage.setAudioOutputId(deviceId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Hoparlör hatası: $e')));
      }
    }
  }

  Future<void> _loadCameraDevices() async {
    if (_loadingCameras) return;
    setState(() {
      _loadingCameras = true;
      _cameraError = null;
    });
    try {
      // Kamera izni iste (cihaz adları için gerekli)
      try {
        final s = await navigator.mediaDevices
            .getUserMedia({'audio': false, 'video': true});
        for (final t in s.getTracks()) {
          t.stop();
        }
      } catch (_) {}
      final devices = await navigator.mediaDevices.enumerateDevices();
      if (!mounted) return;
      setState(() {
        _videoInputs =
            devices.where((d) => d.kind == 'videoinput').toList();
        _camerasLoaded = true;
        _loadingCameras = false;
      });
      // İlk açılışta önizlemeyi otomatik başlat
      if (_selectedCameraId == null && _videoInputs.isNotEmpty) {
        _selectedCameraId = _videoInputs.first.deviceId;
      }
      await _refreshPreview();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cameraError = '$e';
        _loadingCameras = false;
      });
    }
  }

  Future<void> _refreshPreview() async {
    if (_previewBusy) return;
    setState(() => _previewBusy = true);
    try {
      await _disposePreview();
      // Sesli kanaldaki aktif kamera bizim seçimimizle eşleşiyorsa onu göster
      final active = widget.voice.localCameraStream;
      final voiceUsingSelected =
          widget.voice.isCameraSharing &&
              active != null &&
              widget.voice.preferredCameraDeviceId == _selectedCameraId;
      if (voiceUsingSelected) {
        _previewStream = active;
        _previewIsOwned = false;
      } else if (_selectedCameraId != null) {
        // Geçici stream oluştur (sadece önizleme için)
        final w = _selectedCameraWidth;
        final h = (w * 9 / 16).round();
        _previewStream = await navigator.mediaDevices.getUserMedia({
          'audio': false,
          'video': {
            'deviceId': {'exact': _selectedCameraId!},
            'width': {'ideal': w},
            'height': {'ideal': h},
            'frameRate': {
              'ideal': _selectedCameraFps,
              'max': _selectedCameraFps
            },
          },
        });
        _previewIsOwned = true;
      } else {
        return;
      }
      final r = RTCVideoRenderer();
      await r.initialize();
      r.srcObject = _previewStream;
      if (!mounted) {
        await r.dispose();
        return;
      }
      setState(() => _previewRenderer = r);
    } catch (e) {
      if (mounted) setState(() => _cameraError = 'Önizleme: $e');
    } finally {
      if (mounted) setState(() => _previewBusy = false);
    }
  }

  Future<void> _applyCameraSelection() async {
    if (_selectedCameraId == null) return;
    try {
      await widget.voice.setCameraPreferences(
        deviceId: _selectedCameraId,
        width: _selectedCameraWidth,
        fps: _selectedCameraFps,
      );
      await Storage.setCameraDeviceId(_selectedCameraId);
      await Storage.setCameraWidth(_selectedCameraWidth);
      await Storage.setCameraFps(_selectedCameraFps);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Kamera ayarları kaydedildi')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Kamera ayarları uygulanamadı: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF36393F),
      insetPadding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800, maxHeight: 560),
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
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'AYARLAR',
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _sideItem('Hesap', 0, Icons.person),
                    _sideItem('Ses', 1, Icons.volume_up),
                    _sideItem('Kamera', 2, Icons.videocam),
                    const Spacer(),
                    const Divider(color: Colors.white24, height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        icon: const Icon(Icons.logout, size: 16),
                        label: const Text('Çıkış Yap'),
                        onPressed: () {
                          Navigator.of(context).pop();
                          widget.onLogout();
                        },
                      ),
                    ),
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
                    child: _tab == 0
                        ? _buildAccountTab()
                        : _tab == 1
                            ? _buildAudioTab()
                            : _buildCameraTab(),
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
        onTap: () {
          setState(() => _tab = idx);
          if (idx == 2 && !_camerasLoaded) {
            _loadCameraDevices();
          }
        },
        child: Container(
          color: active ? const Color(0xFF393C43) : Colors.transparent,
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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

  Widget _buildAccountTab() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Hesap',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          // Avatar + isim + Resim Seç/Kaldır
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF2F3136),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Stack(
                  children: [
                    UserAvatar(
                      username: widget.username,
                      avatarUrl: _avatarUrl,
                      radius: 32,
                    ),
                    if (_avatarUploading)
                      const Positioned.fill(
                        child: CircleAvatar(
                          backgroundColor: Colors.black54,
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.username,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF5865F2),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 6),
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed:
                                _avatarUploading ? null : _pickAndUploadAvatar,
                            icon: const Icon(Icons.image, size: 14),
                            label: const Text('Resim Seç',
                                style: TextStyle(fontSize: 12)),
                          ),
                          if (_avatarUrl != null)
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.redAccent,
                                side: const BorderSide(
                                    color: Colors.redAccent),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                                visualDensity: VisualDensity.compact,
                              ),
                              onPressed:
                                  _avatarUploading ? null : _removeAvatar,
                              icon: const Icon(Icons.delete, size: 14),
                              label: const Text('Kaldır',
                                  style: TextStyle(fontSize: 12)),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          _label('KULLANICI ADI'),
          const SizedBox(height: 6),
          TextField(
            controller: _usernameCtrl,
            style: const TextStyle(color: Colors.white),
            decoration: _input(),
          ),
          const SizedBox(height: 14),

          _label('E-POSTA'),
          const SizedBox(height: 6),
          TextField(
            controller: _emailCtrl,
            style: const TextStyle(color: Colors.white),
            keyboardType: TextInputType.emailAddress,
            decoration: _input(),
          ),
          const SizedBox(height: 12),

          // Şifre değiştirme bölümü (gizli)
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: Colors.white70,
              padding: EdgeInsets.zero,
              alignment: Alignment.centerLeft,
            ),
            onPressed: () =>
                setState(() => _showPasswordSection = !_showPasswordSection),
            icon: Icon(
              _showPasswordSection ? Icons.expand_less : Icons.expand_more,
              size: 16,
            ),
            label: const Text('Şifre değiştir',
                style: TextStyle(fontSize: 13)),
          ),
          if (_showPasswordSection) ...[
            const SizedBox(height: 8),
            _label('MEVCUT ŞİFRE'),
            const SizedBox(height: 6),
            TextField(
              controller: _currentPasswordCtrl,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: _input(),
            ),
            const SizedBox(height: 14),
            _label('YENİ ŞİFRE'),
            const SizedBox(height: 6),
            TextField(
              controller: _newPasswordCtrl,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: _input(),
            ),
          ],

          if (_profileError != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(_profileError!,
                  style: const TextStyle(color: Colors.redAccent)),
            ),
          ],
          if (_profileSuccess != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF3BA55D).withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(_profileSuccess!,
                  style: const TextStyle(color: Color(0xFF3BA55D))),
            ),
          ],
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF5865F2),
              ),
              icon: _profileLoading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.save, size: 16),
              label: const Text('Profili Kaydet'),
              onPressed: _profileLoading ? null : _saveProfile,
            ),
          ),

          const SizedBox(height: 30),
          const Divider(color: Colors.white12, height: 1),
          const SizedBox(height: 20),

          _label('BAĞLI SUNUCU'),
          const SizedBox(height: 8),
          // Mevcut sunucu kartı + "Sunucuları Yönet" butonu
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF202225),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                const Icon(Icons.dns,
                    color: Color(0xFF5865F2), size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.currentServer,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Text(
                        'Sunucu değişikliği için uygulamayı yeniden başlatman gerekir.',
                        style: TextStyle(
                            color: Colors.white38, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white24),
                  ),
                  icon: const Icon(Icons.swap_horiz, size: 16),
                  label: const Text('Sunucuları Yönet'),
                  onPressed: () async {
                    final navigator = Navigator.of(context);
                    final selected = await showDialog<String>(
                      context: context,
                      builder: (_) => HamachiNetworkDialog(
                        currentHost: widget.currentServer,
                        currentUsername: widget.username,
                      ),
                    );
                    if (selected == null) return;
                    await widget.onSaveServer(selected);
                    navigator.pop();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 30),
          const Divider(color: Colors.white12, height: 1),
          const SizedBox(height: 20),
          _label('UYGULAMA SÜRÜMÜ'),
          const SizedBox(height: 8),
          _label('Güncelleme için updater/updater.exe kullanın'),
        ],
      ),
    );
  }

  Widget _label(String text) => Text(
        text,
        style: const TextStyle(
            color: Colors.white54,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 1),
      );

  InputDecoration _input() => InputDecoration(
        isDense: true,
        filled: true,
        fillColor: const Color(0xFF202225),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide.none,
        ),
      );

  Widget _buildAudioTab() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Ses',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          if (_loadingDevices)
            const Center(child: CircularProgressIndicator())
          else if (_audioError != null)
            Text(_audioError!,
                style: const TextStyle(color: Colors.redAccent))
          else ...[
            const Text('GİRİŞ AYGITI (MİKROFON)',
                style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1)),
            const SizedBox(height: 6),
            _deviceDropdown(
              _audioInputs,
              _selectedInputId,
              _applyInput,
              'Mikrofon seçilmedi',
            ),
            const SizedBox(height: 20),
            const Text('ÇIKIŞ AYGITI (HOPARLÖR/KULAKLIK)',
                style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1)),
            const SizedBox(height: 6),
            _deviceDropdown(
              _audioOutputs,
              _selectedOutputId,
              _applyOutput,
              'Hoparlör seçilmedi',
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF202225),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: const [
                  Icon(Icons.info_outline,
                      color: Colors.white38, size: 14),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Mikrofon değişikliği sesli kanaldaysan anında uygulanır. '
                      'Hoparlör değişikliği tüm aktif sesleri etkiler.',
                      style:
                          TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCameraTab() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Kamera',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          if (_loadingCameras)
            const Center(child: CircularProgressIndicator())
          else if (_cameraError != null && !_camerasLoaded)
            Text(_cameraError!,
                style: const TextStyle(color: Colors.redAccent))
          else if (!_camerasLoaded) ...[
            // Sekme tıklanmadan önce buraya gelir; otomatik yükle.
            const Center(child: CircularProgressIndicator()),
          ] else ...[
            // Önizleme alanı
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white24),
                ),
                clipBehavior: Clip.hardEdge,
                child: _previewRenderer != null
                    ? RTCVideoView(
                        _previewRenderer!,
                        objectFit: RTCVideoViewObjectFit
                            .RTCVideoViewObjectFitCover,
                        mirror: true,
                      )
                    : Center(
                        child: _previewBusy
                            ? const CircularProgressIndicator()
                            : const Icon(Icons.videocam_off,
                                color: Colors.white24, size: 48),
                      ),
              ),
            ),
            const SizedBox(height: 14),

            _label('KAMERA CİHAZI'),
            const SizedBox(height: 6),
            _deviceDropdown(
              _videoInputs,
              _selectedCameraId,
              (id) async {
                if (id == null) return;
                setState(() => _selectedCameraId = id);
                await _refreshPreview();
              },
              'Kamera seçilmedi',
            ),
            const SizedBox(height: 14),

            // İki sütun: çözünürlük + FPS
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _label('ÇÖZÜNÜRLÜK'),
                      const SizedBox(height: 6),
                      _resolutionDropdown(),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _label('FPS'),
                      const SizedBox(height: 6),
                      _fpsDropdown(),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (_cameraError != null) ...[
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(_cameraError!,
                    style: const TextStyle(color: Colors.redAccent)),
              ),
              const SizedBox(height: 10),
            ],
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF202225),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    children: const [
                      Icon(Icons.info_outline,
                          color: Colors.white38, size: 14),
                      SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Sesli kanaldaysan değişiklikler anında uygulanır.',
                          style:
                              TextStyle(color: Colors.white54, fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF5865F2),
                  ),
                  icon: const Icon(Icons.save, size: 16),
                  label: const Text('Kaydet'),
                  onPressed: _applyCameraSelection,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _resolutionDropdown() {
    const options = [
      (label: '360p (640×360)', width: 640),
      (label: '480p (854×480)', width: 854),
      (label: '720p (1280×720)', width: 1280),
      (label: '1080p (1920×1080)', width: 1920),
    ];
    return DropdownButtonFormField<int>(
      initialValue: options.any((o) => o.width == _selectedCameraWidth)
          ? _selectedCameraWidth
          : 1280,
      isExpanded: true,
      dropdownColor: const Color(0xFF202225),
      style: const TextStyle(color: Colors.white),
      decoration: _dropdownDeco(),
      items: [
        for (final o in options)
          DropdownMenuItem(value: o.width, child: Text(o.label)),
      ],
      onChanged: (v) async {
        if (v == null) return;
        setState(() => _selectedCameraWidth = v);
        await _refreshPreview();
      },
    );
  }

  Widget _fpsDropdown() {
    const fpsOptions = [15, 24, 30, 60];
    return DropdownButtonFormField<int>(
      initialValue:
          fpsOptions.contains(_selectedCameraFps) ? _selectedCameraFps : 30,
      isExpanded: true,
      dropdownColor: const Color(0xFF202225),
      style: const TextStyle(color: Colors.white),
      decoration: _dropdownDeco(),
      items: [
        for (final f in fpsOptions)
          DropdownMenuItem(value: f, child: Text('$f FPS')),
      ],
      onChanged: (v) async {
        if (v == null) return;
        setState(() => _selectedCameraFps = v);
        await _refreshPreview();
      },
    );
  }

  InputDecoration _dropdownDeco() => InputDecoration(
        isDense: true,
        filled: true,
        fillColor: const Color(0xFF202225),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide.none,
        ),
      );

  Widget _deviceDropdown(
    List<MediaDeviceInfo> devices,
    String? selectedId,
    Future<void> Function(String?) onChanged,
    String emptyLabel,
  ) {
    return DropdownButtonFormField<String>(
      initialValue:
          devices.any((d) => d.deviceId == selectedId) ? selectedId : null,
      isExpanded: true,
      dropdownColor: const Color(0xFF202225),
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: const Color(0xFF202225),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide.none,
        ),
        hintText: emptyLabel,
        hintStyle: const TextStyle(color: Colors.white38),
      ),
      items: [
        for (final d in devices)
          DropdownMenuItem(
            value: d.deviceId,
            child: Text(
              d.label.isEmpty ? '(isimsiz cihaz)' : d.label,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (v) => onChanged(v),
    );
  }
}

class _ScreenViewerDialog extends StatefulWidget {
  final VoiceManager voice;
  final int myUserId;
  final RTCVideoRenderer? localRenderer;
  final RTCVideoRenderer? localCameraRenderer;
  final Map<int, RTCVideoRenderer> screenRenderers;
  final Map<int, RTCVideoRenderer> cameraRenderers;
  final List<({int userId, String username, bool screenSharing, bool cameraSharing, String? avatarUrl})> members;

  const _ScreenViewerDialog({
    required this.voice,
    required this.myUserId,
    required this.localRenderer,
    required this.localCameraRenderer,
    required this.screenRenderers,
    required this.cameraRenderers,
    required this.members,
  });

  @override
  State<_ScreenViewerDialog> createState() => _ScreenViewerDialogState();
}

class _ScreenViewerDialogState extends State<_ScreenViewerDialog> {
  // Feed anahtarı: "userId:kind" (kind = 'screen' | 'camera')
  String? _focusKey;
  bool _isFullscreen = false;
  bool _controlsVisible = true;
  Timer? _hideTimer;

  // Input control state
  bool _inputModeActive = false;
  // Odaklanan feed ekran paylaşımı mı? (kamera paylaşımına input gönderme)
  bool get _focusedIsScreen {
    if (_focusKey == null) return false;
    return _focusKey!.endsWith(':screen');
  }
  // Kontrol edilebilir mi? (focused feed = başkasının ekran paylaşımı)
  bool get _canControl => _focusedIsScreen;

  @override
  void initState() {
    super.initState();
    widget.voice.addListener(_onVoiceChange);
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.voice.removeListener(_onVoiceChange);
    if (_isFullscreen) {
      windowManager.setFullScreen(false);
    }
    // Input mode'u kapat ve VoiceManager'a bildir
    if (_inputModeActive) {
      _inputModeActive = false;
      widget.voice.setControllingPeer(null);
    }
    super.dispose();
  }

  void _onVoiceChange() {
    if (mounted) setState(() {});
  }

  void _toggleInputMode() {
    if (!_canControl) return;
    setState(() {
      _inputModeActive = !_inputModeActive;
    });
    if (_inputModeActive) {
      // Focused screen'in userId'sini bul
      final userIdStr = _focusKey?.split(':').first;
      if (userIdStr != null) {
        final userId = int.tryParse(userIdStr);
        if (userId != null) {
          widget.voice.setControllingPeer(userId);
        }
      }
    } else {
      widget.voice.setControllingPeer(null);
    }
  }

  void _sendInputEvent(Map<String, dynamic> event) {
    if (!_inputModeActive) return;
    final userIdStr = _focusKey?.split(':').first;
    if (userIdStr == null) return;
    final userId = int.tryParse(userIdStr);
    if (userId == null) return;
    widget.voice.sendInputEvent(userId, event);
  }

  void _sendMouseEvent(String type, Offset localPos, int button) {
    // Video renderer'ın gerçek pixel boyutlarını al
    // localPos zaten video widget'ın koordinatlarında
    _sendInputEvent({
      'type': type,
      'x': localPos.dx.round(),
      'y': localPos.dy.round(),
      if (type != 'mouse_move') 'button': button,
    });
  }

  void _sendWheelEvent(Offset delta) {
    _sendInputEvent({
      'type': 'mouse_wheel',
      'delta': delta.dy.round() * -120, // Windows wheel delta standardı
    });
  }

  void _sendKeyEvent(String type, int keyCode) {
    _sendInputEvent({
      'type': type,
      'keyCode': keyCode,
    });
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _scheduleHide();
  }

  Future<void> _toggleFullscreen() async {
    final next = !_isFullscreen;
    try {
      await windowManager.setFullScreen(next);
      if (mounted) setState(() => _isFullscreen = next);
    } catch (e) {
      debugPrint('Fullscreen hatası: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Tüm aktif video feed'leri topla — ekran + kamera, local + remote
    final feeds = <_VideoFeed>[];
    if (widget.voice.isScreenSharing && widget.localRenderer != null) {
      feeds.add(_VideoFeed(
        key: '${widget.myUserId}:screen',
        userId: widget.myUserId,
        kind: 'screen',
        renderer: widget.localRenderer!,
      ));
    }
    if (widget.voice.isCameraSharing && widget.localCameraRenderer != null) {
      feeds.add(_VideoFeed(
        key: '${widget.myUserId}:camera',
        userId: widget.myUserId,
        kind: 'camera',
        renderer: widget.localCameraRenderer!,
      ));
    }
    for (final entry in widget.screenRenderers.entries) {
      feeds.add(_VideoFeed(
        key: '${entry.key}:screen',
        userId: entry.key,
        kind: 'screen',
        renderer: entry.value,
      ));
    }
    for (final entry in widget.cameraRenderers.entries) {
      feeds.add(_VideoFeed(
        key: '${entry.key}:camera',
        userId: entry.key,
        kind: 'camera',
        renderer: entry.value,
      ));
    }

    // Hiç paylaşım kalmadıysa dialog'u kapat
    if (feeds.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return const SizedBox.shrink();
    }

    _VideoFeed focused = feeds.firstWhere(
      (f) => f.key == _focusKey,
      orElse: () => feeds.first,
    );

    String usernameOf(int userId) {
      if (userId == widget.myUserId) return 'Sen';
      final m = widget.members.where((m) => m.userId == userId).firstOrNull;
      return m?.username ?? 'Bilinmeyen';
    }

    final hasThumbnails = feeds.length > 1;
    final focusedName = usernameOf(focused.userId);
    final kindLabel = focused.kind == 'camera' ? 'kamera' : 'ekran';
    final label = focused.userId == widget.myUserId
        ? 'Senin ${focused.kind == 'camera' ? 'kameran' : 'paylaşımın'}'
        : '$focusedName ($kindLabel)';
    final headerIcon =
        focused.kind == 'camera' ? Icons.videocam : Icons.tv;
    final headerColor =
        focused.kind == 'camera' ? Colors.greenAccent : Colors.orangeAccent;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_inputModeActive) {
            _toggleInputMode();
          } else if (_isFullscreen) {
            _toggleFullscreen();
          } else {
            Navigator.of(context).pop();
          }
        },
        const SingleActivator(LogicalKeyboardKey.f11): _toggleFullscreen,
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (_inputModeActive && _canControl) {
            final key = event.logicalKey.keyId;
            if (event is KeyDownEvent) {
              _sendKeyEvent('key_down', key);
              return KeyEventResult.handled;
            } else if (event is KeyUpEvent) {
              _sendKeyEvent('key_up', key);
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Dialog(
          backgroundColor: Colors.black,
          insetPadding: EdgeInsets.all(_isFullscreen ? 0 : 16),
          shape: _isFullscreen
              ? const RoundedRectangleBorder(borderRadius: BorderRadius.zero)
              : null,
          child: MouseRegion(
            onHover: (_) => _showControls(),
            onEnter: (_) => _showControls(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Arkaplan: video tüm alanı kaplar (boyutu küçülmez)
                Container(
                  color: Colors.black,
                  child: _inputModeActive
                      ? Listener(
                          onPointerDown: (e) {
                            _sendMouseEvent('mouse_move', e.localPosition, 0);
                            final btn = e.kind == PointerDeviceKind.touch ? 0
                              : (e.buttons & 0x01) != 0 ? 0
                              : (e.buttons & 0x02) != 0 ? 1 : 2;
                            _sendMouseEvent('mouse_down', e.localPosition, btn);
                          },
                          onPointerUp: (e) {
                            final btn = (e.buttons & 0x01) != 0 ? 0
                              : (e.buttons & 0x02) != 0 ? 1 : 2;
                            _sendMouseEvent('mouse_up', e.localPosition, btn);
                          },
                          onPointerMove: (e) {
                            _sendMouseEvent('mouse_move', e.localPosition, 0);
                          },
                          onPointerSignal: (e) {
                            if (e is PointerScrollEvent) {
                              _sendWheelEvent(e.scrollDelta);
                            }
                          },
                          child: MouseRegion(
                            cursor: SystemMouseCursors.none,
                            child: RTCVideoView(
                              focused.renderer,
                              objectFit: RTCVideoViewObjectFit
                                  .RTCVideoViewObjectFitContain,
                            ),
                          ),
                        )
                      : RTCVideoView(
                          focused.renderer,
                          objectFit: RTCVideoViewObjectFit
                              .RTCVideoViewObjectFitContain,
                        ),
                ),

                // Üst kontrol bar — şeffaf overlay, fare hareketiyle açılıp 2sn sonra kapanır
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 250),
                      opacity: _controlsVisible ? 1.0 : 0.0,
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Color(0xCC000000),
                              Color(0x00000000),
                            ],
                          ),
                        ),
                        padding: const EdgeInsets.fromLTRB(12, 8, 8, 24),
                        child: Row(
                          children: [
                            Icon(headerIcon, color: headerColor, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                label,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black,
                                      blurRadius: 6,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            // Input control toggle (ekran paylaşımı varsa göster)
                            if (_canControl)
                              IconButton(
                                icon: Icon(
                                  _inputModeActive
                                      ? Icons.mouse
                                      : Icons.mouse_outlined,
                                  color: _inputModeActive
                                      ? Colors.greenAccent
                                      : Colors.white,
                                ),
                                tooltip: _inputModeActive
                                    ? 'Uzaktan kontrol aktif (ESC ile kapat)'
                                    : 'Uzaktan kontrolü başlat',
                                onPressed: _toggleInputMode,
                              ),
                            IconButton(
                              icon: Icon(
                                _isFullscreen
                                    ? Icons.fullscreen_exit
                                    : Icons.fullscreen,
                                color: Colors.white,
                              ),
                              tooltip: _isFullscreen
                                  ? 'Tam ekrandan çık (ESC)'
                                  : 'Tam ekran (F11)',
                              onPressed: _toggleFullscreen,
                            ),
                            IconButton(
                              icon: const Icon(Icons.close,
                                  color: Colors.white),
                              tooltip: 'Kapat',
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // Input mode göstergesi (aktifken her zaman görünür)
                if (_inputModeActive)
                  Positioned(
                    top: 56,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.greenAccent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                                color: Colors.greenAccent.withValues(alpha: 0.5)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.mouse,
                                  color: Colors.greenAccent, size: 16),
                              const SizedBox(width: 8),
                              Text(
                                'Uzaktan kontrol aktif — ESC ile kapat',
                                style: const TextStyle(
                                  color: Colors.greenAccent,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                // Alt thumbnail bar (birden fazla paylaşım varsa) — yine overlay + fade
                if (hasThumbnails)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      ignoring: !_controlsVisible,
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 250),
                        opacity: _controlsVisible ? 1.0 : 0.0,
                        child: Container(
                          height: 100,
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [
                                Color(0xCC000000),
                                Color(0x00000000),
                              ],
                            ),
                          ),
                          padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: feeds.map((f) {
                              final selected = f.key == focused.key;
                              final name = usernameOf(f.userId);
                              final icon = f.kind == 'camera'
                                  ? Icons.videocam
                                  : Icons.tv;
                              return GestureDetector(
                                onTap: () =>
                                    setState(() => _focusKey = f.key),
                                child: Container(
                                  width: 110,
                                  margin: const EdgeInsets.only(right: 8),
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: selected
                                          ? const Color(0xFF5865F2)
                                          : Colors.white24,
                                      width: 2,
                                    ),
                                  ),
                                  child: Stack(
                                    children: [
                                      Positioned.fill(
                                        child: RTCVideoView(
                                          f.renderer,
                                          objectFit: RTCVideoViewObjectFit
                                              .RTCVideoViewObjectFitCover,
                                        ),
                                      ),
                                      Positioned(
                                        left: 4,
                                        top: 4,
                                        child: Container(
                                          color: Colors.black54,
                                          padding: const EdgeInsets.all(2),
                                          child: Icon(icon,
                                              size: 11,
                                              color: f.kind == 'camera'
                                                  ? Colors.greenAccent
                                                  : Colors.orangeAccent),
                                        ),
                                      ),
                                      Positioned(
                                        left: 4,
                                        bottom: 4,
                                        child: Container(
                                          color: Colors.black54,
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 4, vertical: 1),
                                          child: Text(
                                            name,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Picker dialog'u şu üç sonuçtan birini Navigator.pop ile döndürebilir:
/// - `String sourceId`: seçilen kaynak (yeni paylaşımı başlat)
/// - `kScreenPickerStop` ('__STOP__'): kullanıcı paylaşımı durdurmak istiyor
/// - `null`: iptal
const String kScreenPickerStop = '__STOP__';

class _ScreenSourcePicker extends StatefulWidget {
  final List<DesktopCapturerSource> screens;
  final List<DesktopCapturerSource> windows;
  final bool isCurrentlySharing;
  final Future<void> Function()? onOpenSettings;
  const _ScreenSourcePicker({
    required this.screens,
    required this.windows,
    this.isCurrentlySharing = false,
    this.onOpenSettings,
  });

  @override
  State<_ScreenSourcePicker> createState() => _ScreenSourcePickerState();
}

class _ScreenSourcePickerState extends State<_ScreenSourcePicker> {
  int _tab = 0; // 0 = ekranlar, 1 = pencereler

  @override
  Widget build(BuildContext context) {
    final sources = _tab == 0 ? widget.screens : widget.windows;
    return Dialog(
      backgroundColor: const Color(0xFF2F3136),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.isCurrentlySharing
                          ? 'Paylaşılan kaynağı değiştir'
                          : 'Paylaşmak için bir kaynak seç',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (widget.isCurrentlySharing)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                        ),
                        icon: const Icon(Icons.stop_screen_share, size: 18),
                        label: const Text('Paylaşımı Durdur'),
                        onPressed: () =>
                            Navigator.of(context).pop(kScreenPickerStop),
                      ),
                    ),
                  if (widget.onOpenSettings != null)
                    IconButton(
                      icon: const Icon(Icons.settings, color: Colors.white70),
                      tooltip: 'Yayın ayarları (bitrate, FPS, çözünürlük)',
                      onPressed: () async {
                        await widget.onOpenSettings!();
                      },
                    ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    tooltip: 'İptal',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _tabButton('Ekranlar (${widget.screens.length})', 0),
                  const SizedBox(width: 8),
                  _tabButton('Pencereler (${widget.windows.length})', 1),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: sources.isEmpty
                  ? const Center(
                      child: Text(
                        'Hiç kaynak bulunamadı.',
                        style: TextStyle(color: Colors.white54),
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 220,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 1.3,
                      ),
                      itemCount: sources.length,
                      itemBuilder: (_, i) => _SourceTile(
                        source: sources[i],
                        onTap: () =>
                            Navigator.of(context).pop(sources[i].id),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabButton(String text, int idx) {
    final selected = _tab == idx;
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: selected
            ? const Color(0xFF5865F2)
            : const Color(0xFF40444B),
      ),
      onPressed: () => setState(() => _tab = idx),
      child: Text(text),
    );
  }
}

class _SourceTile extends StatefulWidget {
  final DesktopCapturerSource source;
  final VoidCallback onTap;
  const _SourceTile({required this.source, required this.onTap});

  @override
  State<_SourceTile> createState() => _SourceTileState();
}

class _SourceTileState extends State<_SourceTile> {
  StreamSubscription? _thumbSub;

  @override
  void initState() {
    super.initState();
    // Thumbnail güncellemelerini dinle (paket otomatik gönderir)
    _thumbSub = widget.source.onThumbnailChanged.stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _thumbSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final thumb = widget.source.thumbnail;
    return InkWell(
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF202225),
          borderRadius: BorderRadius.circular(6),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                color: Colors.black,
                child: thumb != null
                    ? Image.memory(
                        thumb,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      )
                    : const Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                widget.source.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ekran/kamera viewer dialog'unda kullanılan video feed temsili.
class _VideoFeed {
  final String key; // "userId:kind"
  final int userId;
  final String kind; // 'screen' | 'camera'
  final RTCVideoRenderer renderer;
  _VideoFeed({
    required this.key,
    required this.userId,
    required this.kind,
    required this.renderer,
  });
}

