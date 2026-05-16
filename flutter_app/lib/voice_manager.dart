import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'screen_share_options.dart';

typedef SignalSender = void Function(int toUserId, Map<String, dynamic> payload);

/// Sesli kanal için her bir uzak kullanıcıyı temsil eder.
class VoicePeer {
  final int userId;
  final String username;
  final RTCPeerConnection pc;
  MediaStream? remoteAudioStream;
  MediaStream? remoteScreenStream;
  MediaStream? remoteCameraStream;
  RTCDataChannel? inputChannel; // uzaktan kontrol için data channel
  VoicePeer({required this.userId, required this.username, required this.pc});
}

/// WebRTC tabanlı sesli görüşme yöneticisi (mesh peer-to-peer).
///
/// - join(channelId, existingMembers): kanala katılır, var olan üyelere offer gönderir
/// - onSignal(...): backend'den gelen signaling mesajını işler
/// - onMemberJoined(userId, username): yeni biri kanala katıldı (offer beklenecek)
/// - onMemberLeft(userId): biri ayrıldı, peer connection'ı kapat
class VoiceManager extends ChangeNotifier {
  final SignalSender _sendSignal;
  VoiceManager({required SignalSender sendSignal}) : _sendSignal = sendSignal;

  static const _rtcConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  int? _currentChannelId;
  MediaStream? _localStream;
  MediaStream? _screenStream;
  MediaStream? _cameraStream;
  final Map<int, VoicePeer> _peers = {};
  // peer userId -> [screen audio/video sender'lar]
  final Map<int, List<RTCRtpSender>> _screenSenders = {};
  // peer userId -> [camera video sender]
  final Map<int, List<RTCRtpSender>> _cameraSenders = {};
  // peer userId -> volume multiplier (0.0 = sessiz, 1.0 = normal, 2.0 = 200%)
  final Map<int, double> _peerVolumes = {};
  // peer userId -> { stream.id -> 'camera' | 'screen' } — uzak video track'i
  // hangi tür olduğunu belirlemek için signal channel üzerinden gelen bilgi
  final Map<int, Map<String, String>> _peerStreamTypes = {};
  // En son kullanılan ekran paylaşımı ayarları (yeni peer'lar için)
  ScreenShareOptions _lastScreenOpts = ScreenShareOptions.defaults;
  bool _muted = false;
  bool _deafened = false;
  bool _isScreenSharing = false;
  bool _isCameraSharing = false;
  String? _preferredCameraDeviceId;
  int _preferredCameraWidth = 1280;
  int _preferredCameraFps = 30;
  // Speaking tespiti — userId -> audio level (0.0-1.0)
  final Map<int, double> _audioLevels = {};
  Timer? _audioLevelTimer;
  static const double _speakingThreshold = 0.05;
  // Input control: hangi peer'ın ekranını kontrol ediyoruz (userId)
  // null = kontrol yok
  int? _controllingPeerId;

  /// Backend'e "ekran paylaşımı başladı/bitti" sinyali için callback.
  /// ChatScreen tarafından set edilir.
  void Function(bool sharing)? onScreenStateChanged;

  /// Backend'e "kamera paylaşımı başladı/bitti" sinyali için callback.
  void Function(bool sharing)? onCameraStateChanged;

  /// Uzaktan input event geldiğinde çağrılır (receiver tarafı).
  /// payload: {type: 'mouse_move'|'mouse_down'|'mouse_up'|'mouse_wheel'|'key_down'|'key_up', ...}
  void Function(Map<String, dynamic> payload)? onInputEvent;

  int? get currentChannelId => _currentChannelId;
  bool get inVoice => _currentChannelId != null;
  bool get isMuted => _muted;
  bool get isDeafened => _deafened;
  bool get isScreenSharing => _isScreenSharing;
  bool get isCameraSharing => _isCameraSharing;
  MediaStream? get localScreenStream => _screenStream;
  MediaStream? get localCameraStream => _cameraStream;
  String? get preferredCameraDeviceId => _preferredCameraDeviceId;
  int get preferredCameraWidth => _preferredCameraWidth;
  int get preferredCameraFps => _preferredCameraFps;

  /// Kamera tercihlerini ayarlar. Sesli kanalda kamera aktifse ve cihaz
  /// değiştiyse switchCamera otomatik çağrılır.
  Future<void> setCameraPreferences({
    String? deviceId,
    int? width,
    int? fps,
  }) async {
    final deviceChanged =
        deviceId != null && deviceId != _preferredCameraDeviceId;
    if (deviceId != null) _preferredCameraDeviceId = deviceId;
    if (width != null) _preferredCameraWidth = width;
    if (fps != null) _preferredCameraFps = fps;
    if (deviceChanged && _isCameraSharing) {
      await switchCamera(deviceId);
    }
  }
  Iterable<VoicePeer> get peers => _peers.values;
  int get screenShareAudioTrackCount =>
      _screenStream?.getAudioTracks().length ?? 0;
  int get screenShareVideoTrackCount =>
      _screenStream?.getVideoTracks().length ?? 0;

  /// Bir kullanıcının şu an konuşup konuşmadığını döndürür
  /// (audio level > threshold). Kendi userId verilirse local mikrofon level'ı.
  bool isUserSpeaking(int userId) {
    final level = _audioLevels[userId] ?? 0.0;
    return level > _speakingThreshold;
  }

  double audioLevelOf(int userId) => _audioLevels[userId] ?? 0.0;

  Future<void> join(
    int channelId,
    List<({int userId, String username})> existingMembers,
  ) async {
    if (_currentChannelId != null) await leave();

    final audioConstraint = _preferredAudioInputId != null
        ? {'deviceId': {'exact': _preferredAudioInputId!}}
        : true;
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': audioConstraint,
      'video': false,
    });
    _currentChannelId = channelId;
    _muted = false;
    notifyListeners();

    // Var olan her üyeye offer gönder
    for (final m in existingMembers) {
      await _createPeerAndOffer(m.userId, m.username);
    }

    _startAudioLevelMonitor();
  }

  void _startAudioLevelMonitor() {
    _audioLevelTimer?.cancel();
    _audioLevelTimer = Timer.periodic(const Duration(milliseconds: 200),
        (_) => _pollAudioLevels());
  }

  void _stopAudioLevelMonitor() {
    _audioLevelTimer?.cancel();
    _audioLevelTimer = null;
    _audioLevels.clear();
  }

  Future<void> _pollAudioLevels() async {
    // Her peer için inbound audio level + bizim local sender level'ımız
    final newLevels = <int, double>{};
    for (final entry in _peers.entries) {
      final peerId = entry.key;
      final pc = entry.value.pc;
      try {
        final stats = await pc.getStats();
        double maxLevel = 0.0;
        for (final r in stats) {
          final values = r.values;
          final type = r.type;
          final kind = (values['kind'] ?? values['mediaType'])?.toString();
          if (kind != 'audio') continue;
          if (type == 'inbound-rtp') {
            final lvl = (values['audioLevel'] as num?)?.toDouble() ?? 0.0;
            if (lvl > maxLevel) maxLevel = lvl;
          }
        }
        newLevels[peerId] = maxLevel;
      } catch (_) {/* yoksay */}
    }

    // Local user için outbound audio level'ı ilk peer'dan al (sender stats)
    if (_peers.isNotEmpty && _localStream != null) {
      try {
        final firstPc = _peers.values.first.pc;
        final stats = await firstPc.getStats();
        double maxLevel = 0.0;
        for (final r in stats) {
          final values = r.values;
          final kind = (values['kind'] ?? values['mediaType'])?.toString();
          if (kind != 'audio') continue;
          if (r.type == 'media-source' || r.type == 'outbound-rtp') {
            final lvl = (values['audioLevel'] as num?)?.toDouble() ?? 0.0;
            if (lvl > maxLevel) maxLevel = lvl;
          }
        }
        // Kendi userId'mizi bilmiyoruz, ama UI _auth.userId ile sorgulayacak.
        // Geçici çözüm: -1 anahtarı kullan, isUserSpeaking için ayrı getter
        // olarak local level'ı saklayalım — ama daha temizi: setMyUserId().
        newLevels[_myUserId ?? -1] = maxLevel;
      } catch (_) {}
    }

    // Mute ise kendi level'ımız 0
    if (_muted && _myUserId != null) {
      newLevels[_myUserId!] = 0.0;
    }

    _audioLevels
      ..clear()
      ..addAll(newLevels);
    notifyListeners();
  }

  /// ChatScreen tarafından bir kez set edilir (auth.userId).
  /// Local audio level'ı isUserSpeaking(myUserId) ile sorgulayabilmek için.
  int? _myUserId;
  void setMyUserId(int userId) {
    _myUserId = userId;
  }

  Future<void> leave() async {
    _stopAudioLevelMonitor();
    // Ekran paylaşımı varsa önce durdur
    if (_isScreenSharing) {
      await stopScreenShare(notifyServer: false);
    }
    if (_isCameraSharing) {
      await stopCamera(notifyServer: false);
    }
    final ids = _peers.keys.toList();
    for (final id in ids) {
      await _closePeer(id);
    }
    if (_localStream != null) {
      for (final t in _localStream!.getTracks()) {
        await t.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    }
    _peerStreamTypes.clear();
    _currentChannelId = null;
    _muted = false;
    notifyListeners();
  }

  /// Ekran paylaşımını başlatır.
  ///
  /// - [sourceId]: Desktop'ta zorunlu (Screen/Window ID), mobile/web'de null.
  /// - [options]: çözünürlük, FPS ve maks. bitrate. null ise varsayılan.
  Future<void> startScreenShare({
    String? sourceId,
    ScreenShareOptions? options,
  }) async {
    final opts = options ?? ScreenShareOptions.defaults;
    if (_isScreenSharing || !inVoice) {
      throw Exception('Ekran paylaşmadan önce sesli kanala katılmalısın');
    }

    // flutter_webrtc Windows'ta birden fazla constraint formatı destekler.
    // Birinci deneme: deviceId. Hata olursa chromeMediaSource fallback'i.
    debugPrint('[VOICE] getDisplayMedia çağrılıyor (sourceId=$sourceId)...');

    // Native cache'i tazele — getSources() çağrısı sourceId lookup için
    // kaynak listesini günceller. Bunu yapmazsak Windows'ta "source not found"
    // hatası alabiliyoruz (özellikle Screen kaynaklarında).
    if (sourceId != null) {
      try {
        await desktopCapturer.getSources(
          types: [SourceType.Screen, SourceType.Window],
        );
      } catch (e) {
        debugPrint('[VOICE] Source listesi tazelenemedi: $e');
      }
    }

    MediaStream? stream;
    Object? lastError;

    // Çözünürlük/FPS constraint'leri — ideal değerler, kaynak destekliyorsa uygulanır
    final qualityConstraints = <String, dynamic>{
      'width': {'ideal': opts.width},
      'height': {'ideal': opts.height},
      'frameRate': {'ideal': opts.frameRate, 'max': opts.frameRate},
    };

    if (sourceId == null) {
      // Mobile/web: sistem dialog'u — sistem sesini de yakalamayı dene
      stream = await navigator.mediaDevices.getDisplayMedia({
        'video': qualityConstraints,
        'audio': true,
      });
    } else {
      // Deneme 1: deviceId + audio: true (yeni standard API)
      try {
        stream = await navigator.mediaDevices.getDisplayMedia({
          'video': {
            'deviceId': {'exact': sourceId},
            ...qualityConstraints,
          },
          'audio': true,
        });
      } catch (e) {
        lastError = e;
        debugPrint('[VOICE] Deneme 1 (deviceId+audio) basarisiz: $e');
      }

      // Deneme 2: chrome-style — video ve audio için ayrı chromeMediaSource
      if (stream == null) {
        try {
          stream = await navigator.mediaDevices.getDisplayMedia({
            'video': {
              'mandatory': {
                'chromeMediaSource': 'desktop',
                'chromeMediaSourceId': sourceId,
                'maxWidth': opts.width,
                'maxHeight': opts.height,
                'maxFrameRate': opts.frameRate,
              },
            },
            'audio': {
              'mandatory': {
                'chromeMediaSource': 'desktop',
              },
            },
          });
        } catch (e) {
          lastError = e;
          debugPrint('[VOICE] Deneme 2 (chromeMediaSource) basarisiz: $e');
        }
      }

      // Deneme 3: sadece video (sistem sesi yakalanamadıysa video yine paylaşılsın)
      if (stream == null) {
        try {
          stream = await navigator.mediaDevices.getDisplayMedia({
            'video': {'deviceId': sourceId},
            'audio': false,
          });
        } catch (e) {
          lastError = e;
          debugPrint('[VOICE] Deneme 3 (video-only) basarisiz: $e');
        }
      }
    }

    if (stream == null) {
      throw Exception(
          'Ekran yakalanamadı. sourceId="$sourceId". Son hata: $lastError');
    }

    _screenStream = stream;
    debugPrint(
        '[VOICE] Stream alındı, video track sayısı: ${_screenStream!.getVideoTracks().length}');

    // Track bittiğinde (kullanıcı sistemden durdurursa) otomatik kapan
    final videoTracks = _screenStream!.getVideoTracks();
    if (videoTracks.isNotEmpty) {
      videoTracks.first.onEnded = () => stopScreenShare();
    }

    // Ekran paylaşımı stream'inde video + (varsa) WASAPI sistem audio track'i
    // — native side otomatik ekliyor (process loopback exclusion ile bizim
    // app'in çıkışı hariç tutulur).
    final allTracks = _screenStream!.getTracks();
    debugPrint(
        '[VOICE] Ekran paylaşımı: ${videoTracks.length} video, ${allTracks.length - videoTracks.length} audio track');

    // Her peer'a video + (varsa) audio track'lerini ekle, sonra renegotiate
    for (final peer in _peers.values) {
      final senders = <RTCRtpSender>[];
      for (final track in allTracks) {
        final sender = await peer.pc.addTrack(track, _screenStream!);
        senders.add(sender);
      }
      _screenSenders[peer.userId] = senders;
      // Bitrate limitini sadece video track'lere uygula
      await _applyBitrate(senders, opts.maxBitrateKbps);
      await _renegotiate(peer);
    }

    _lastScreenOpts = opts;
    _isScreenSharing = true;
    onScreenStateChanged?.call(true);
    notifyListeners();
  }

  /// Ekran paylaşımı aktifken kaynağı değiştirir.
  /// stop+start yerine sender.replaceTrack kullanır — m-line aynı kalır,
  /// SDP değişmez, renegotiate gerekmez. Bu sayede karşı tarafta donma olmaz.
  Future<void> replaceScreenSource({
    String? sourceId,
    ScreenShareOptions? options,
  }) async {
    if (!_isScreenSharing) {
      return startScreenShare(sourceId: sourceId, options: options);
    }
    final opts = options ?? _lastScreenOpts;

    // Yeni stream al
    final qualityConstraints = <String, dynamic>{
      'width': {'ideal': opts.width},
      'height': {'ideal': opts.height},
      'frameRate': {'ideal': opts.frameRate, 'max': opts.frameRate},
    };

    MediaStream? newStream;
    Object? lastError;
    final tries = sourceId == null
        ? [
            {
              'video': qualityConstraints,
              'audio': true,
            },
          ]
        : [
            {
              'video': {
                'deviceId': {'exact': sourceId},
                ...qualityConstraints,
              },
              'audio': true,
            },
            {
              'video': {
                'mandatory': {
                  'chromeMediaSource': 'desktop',
                  'chromeMediaSourceId': sourceId,
                  'maxWidth': opts.width,
                  'maxHeight': opts.height,
                  'maxFrameRate': opts.frameRate,
                },
              },
              'audio': {
                'mandatory': {'chromeMediaSource': 'desktop'},
              },
            },
            {
              'video': {'deviceId': sourceId},
              'audio': false,
            },
          ];
    for (final c in tries) {
      try {
        newStream =
            await navigator.mediaDevices.getDisplayMedia(c);
        break;
      } catch (e) {
        lastError = e;
      }
    }
    if (newStream == null) {
      throw Exception('Yeni kaynak alınamadı: $lastError');
    }

    final newVideo = newStream.getVideoTracks();
    final newAudio = newStream.getAudioTracks();

    if (newVideo.isEmpty) {
      for (final t in newStream.getTracks()) {
        await t.stop();
      }
      throw Exception('Yeni kaynakta video track yok');
    }

    // Track ended callback (kullanıcı sistem'den durdurursa)
    newVideo.first.onEnded = () => stopScreenShare();

    // Her peer için: var olan sender'ları sırayla yeni track'lerle değiştir.
    // m-line ve transceiver aynı kalır → SDP değişmez → renegotiate gerekmez.
    for (final entry in _screenSenders.entries) {
      final peer = _peers[entry.key];
      if (peer == null) continue;

      int videoIdx = 0;
      int audioIdx = 0;
      for (final sender in entry.value) {
        final kind = sender.track?.kind;
        if (kind == 'video' && videoIdx < newVideo.length) {
          try {
            await sender.replaceTrack(newVideo[videoIdx]);
            videoIdx++;
          } catch (e) {
            debugPrint('[VOICE] Video replaceTrack hatası: $e');
          }
        } else if (kind == 'audio' && audioIdx < newAudio.length) {
          try {
            await sender.replaceTrack(newAudio[audioIdx]);
            audioIdx++;
          } catch (e) {
            debugPrint('[VOICE] Audio replaceTrack hatası: $e');
          }
        }
      }
    }

    // Eski stream'i temizle
    final oldStream = _screenStream;
    if (oldStream != null) {
      for (final t in oldStream.getTracks()) {
        try {
          await t.stop();
        } catch (_) {}
      }
      try {
        await oldStream.dispose();
      } catch (_) {}
    }

    _screenStream = newStream;
    _lastScreenOpts = opts;
    debugPrint(
        '[VOICE] Ekran kaynağı değişti (renegotiate yok): ${newVideo.length} video, ${newAudio.length} audio track');
    notifyListeners();
  }

  Future<void> _applyBitrate(
      List<RTCRtpSender> senders, int maxBitrateKbps) async {
    final videoBitrateBps = maxBitrateKbps * 1000;
    // Sistem sesi (müzik/oyun) için 128 kbps stereo opus — HiFi kalite.
    // WebRTC opus varsayılanı VoIP için ~32 kbps mono, müzik için çok düşük.
    const int audioBitrateBps = 128 * 1000;

    for (final sender in senders) {
      final kind = sender.track?.kind;
      final bps = kind == 'video' ? videoBitrateBps : audioBitrateBps;
      try {
        final params = sender.parameters;
        final encodings = params.encodings ?? <RTCRtpEncoding>[];
        if (encodings.isEmpty) {
          encodings.add(RTCRtpEncoding(maxBitrate: bps));
        } else {
          for (final enc in encodings) {
            enc.maxBitrate = bps;
          }
        }
        params.encodings = encodings;
        await sender.setParameters(params);
      } catch (e) {
        debugPrint('[VOICE] Bitrate ayarlanamadı ($kind): $e');
      }
    }
  }

  /// [skipRenegotiate]: kaynak değiştirme sırasında stop+start ardışık
  /// çağrıldığında iki ayrı renegotiate yapmayı engeller (glare/race
  /// condition önler). startScreenShare'in renegotiate'i yeterli olur.
  Future<void> stopScreenShare(
      {bool notifyServer = true, bool skipRenegotiate = false}) async {
    if (!_isScreenSharing) return;

    // Track'leri peer connection'lardan çıkar
    for (final entry in _screenSenders.entries) {
      final peer = _peers[entry.key];
      if (peer == null) continue;
      for (final sender in entry.value) {
        try {
          await peer.pc.removeTrack(sender);
        } catch (_) {/* peer kapalı olabilir */}
      }
      if (!skipRenegotiate) {
        await _renegotiate(peer);
      }
    }
    _screenSenders.clear();

    if (_screenStream != null) {
      for (final t in _screenStream!.getTracks()) {
        await t.stop();
      }
      await _screenStream!.dispose();
      _screenStream = null;
    }
    _isScreenSharing = false;
    if (notifyServer) onScreenStateChanged?.call(false);
    notifyListeners();
  }

  /// Bir peer'a "şu stream.id şu tipte" (camera|screen) bilgisini gönderir.
  /// onTrack'te gelen uzak video track'lerini doğru kategoriye atamak için.
  void _sendStreamInfo(int peerId, String streamId, String kind) {
    _sendSignal(peerId, {
      'kind': 'stream-info',
      'streamId': streamId,
      'streamKind': kind,
    });
  }

  /// Kamerayı (webcam) başlatır ve her peer'a video track'i ekler.
  /// Ekran paylaşımıyla aynı anda kullanılabilir.
  Future<void> startCamera({String? deviceId}) async {
    if (_isCameraSharing || !inVoice) {
      throw Exception('Kamera için sesli kanala katılmalısın');
    }
    final effectiveId = deviceId ?? _preferredCameraDeviceId;
    final w = _preferredCameraWidth;
    // 16:9 oranında yükseklik
    final h = (w * 9 / 16).round();
    final videoConstraint = <String, dynamic>{
      'width': {'ideal': w},
      'height': {'ideal': h},
      'frameRate': {'ideal': _preferredCameraFps, 'max': _preferredCameraFps},
    };
    if (effectiveId != null) {
      videoConstraint['deviceId'] = {'exact': effectiveId};
    }
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': videoConstraint,
    });
    _cameraStream = stream;
    _preferredCameraDeviceId = deviceId;

    // Track bitince (cihaz çekildi vs.) otomatik kapan
    final tracks = stream.getVideoTracks();
    if (tracks.isNotEmpty) {
      tracks.first.onEnded = () => stopCamera();
    }

    // Her peer'a video track ekle + renegotiate + stream-info gönder
    for (final peer in _peers.values) {
      final senders = <RTCRtpSender>[];
      for (final track in stream.getVideoTracks()) {
        final sender = await peer.pc.addTrack(track, stream);
        senders.add(sender);
      }
      _cameraSenders[peer.userId] = senders;
      // Kamera için makul bir bitrate (2.5 Mbps)
      await _applyBitrate(senders, 2500);
      _sendStreamInfo(peer.userId, stream.id, 'camera');
      await _renegotiate(peer);
    }

    _isCameraSharing = true;
    onCameraStateChanged?.call(true);
    notifyListeners();
  }

  /// Kamerayı durdurur ve track'leri tüm peer'lardan kaldırır.
  Future<void> stopCamera({bool notifyServer = true}) async {
    if (!_isCameraSharing) return;
    for (final entry in _cameraSenders.entries) {
      final peer = _peers[entry.key];
      if (peer == null) continue;
      for (final sender in entry.value) {
        try {
          await peer.pc.removeTrack(sender);
        } catch (_) {}
      }
      await _renegotiate(peer);
    }
    _cameraSenders.clear();
    if (_cameraStream != null) {
      for (final t in _cameraStream!.getTracks()) {
        await t.stop();
      }
      await _cameraStream!.dispose();
      _cameraStream = null;
    }
    _isCameraSharing = false;
    if (notifyServer) onCameraStateChanged?.call(false);
    notifyListeners();
  }

  /// Kamera cihazını değiştirir. Aktif kamera varsa replaceTrack kullanır
  /// (renegotiate yok → diğer kullanıcılarda donma olmaz).
  Future<void> switchCamera(String deviceId) async {
    _preferredCameraDeviceId = deviceId;
    if (!_isCameraSharing || _cameraStream == null) return;
    try {
      final w = _preferredCameraWidth;
      final h = (w * 9 / 16).round();
      final newStream = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {
          'deviceId': {'exact': deviceId},
          'width': {'ideal': w},
          'height': {'ideal': h},
          'frameRate': {'ideal': _preferredCameraFps, 'max': _preferredCameraFps},
        },
      });
      final newTrack = newStream.getVideoTracks().first;
      newTrack.onEnded = () => stopCamera();

      for (final entry in _cameraSenders.entries) {
        for (final sender in entry.value) {
          try {
            await sender.replaceTrack(newTrack);
          } catch (_) {}
        }
      }
      // Eski stream'i kapat
      for (final t in _cameraStream!.getTracks()) {
        try {
          await t.stop();
        } catch (_) {}
      }
      await _cameraStream!.dispose();
      _cameraStream = newStream;
      // Yeni stream.id farklı — peer'lara haber ver
      for (final peerId in _peers.keys) {
        _sendStreamInfo(peerId, newStream.id, 'camera');
      }
      notifyListeners();
    } catch (e) {
      debugPrint('[VOICE] Kamera değiştirilemedi: $e');
      rethrow;
    }
  }

  Future<void> _renegotiate(VoicePeer peer) async {
    final offer = await peer.pc.createOffer({});
    await peer.pc.setLocalDescription(offer);
    _sendSignal(peer.userId, {
      'kind': 'offer',
      'sdp': offer.sdp,
      'type': offer.type,
    });
  }

  /// Mikrofon cihazını değiştir. Sesli kanaldaysa local stream
  /// yeniden başlatılır ve her peer'a track replaceTrack ile uygulanır.
  Future<void> selectAudioInput(String deviceId) async {
    _preferredAudioInputId = deviceId;
    if (!inVoice || _localStream == null) return;

    try {
      final newStream = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'deviceId': {'exact': deviceId},
        },
        'video': false,
      });
      final newTrack = newStream.getAudioTracks().first;
      // Her peer'ın mikrofon sender'ında replaceTrack
      for (final peer in _peers.values) {
        final senders = await peer.pc.getSenders();
        for (final s in senders) {
          if (s.track?.kind == 'audio' &&
              s.track?.id != newTrack.id &&
              // Sender screen/kamera audio değil mikrofon olmalı
              !_isScreenSender(peer.userId, s) &&
              !_isCameraSender(peer.userId, s)) {
            try {
              await s.replaceTrack(newTrack);
            } catch (_) {}
          }
        }
      }
      // Eski stream temizle
      for (final t in _localStream!.getTracks()) {
        try {
          await t.stop();
        } catch (_) {}
      }
      await _localStream!.dispose();
      _localStream = newStream;
      _applyAudioState();
      notifyListeners();
    } catch (e) {
      debugPrint('[VOICE] Mikrofon değiştirilemedi: $e');
      rethrow;
    }
  }

  bool _isScreenSender(int userId, RTCRtpSender sender) {
    final list = _screenSenders[userId];
    return list != null && list.contains(sender);
  }

  bool _isCameraSender(int userId, RTCRtpSender sender) {
    final list = _cameraSenders[userId];
    return list != null && list.contains(sender);
  }

  /// Çıkış cihazını (hoparlör/kulaklık) değiştir.
  /// Tüm RTCVideoRenderer'lara uygulanır (flutter_webrtc global API).
  Future<void> selectAudioOutput(String deviceId) async {
    _preferredAudioOutputId = deviceId;
    try {
      await Helper.selectAudioOutput(deviceId);
    } catch (e) {
      debugPrint('[VOICE] Çıkış cihazı değiştirilemedi: $e');
      rethrow;
    }
  }

  String? _preferredAudioInputId;
  String? _preferredAudioOutputId;
  String? get preferredAudioInputId => _preferredAudioInputId;
  String? get preferredAudioOutputId => _preferredAudioOutputId;

  void toggleMute() {
    _muted = !_muted;
    _applyAudioState();
    notifyListeners();
  }

  /// Belirli bir kullanıcının ses seviyesini ayarla (0.0 - 2.0).
  /// Bilgisayarın master volume'ünden bağımsız çalışır.
  Future<void> setPeerVolume(int userId, double volume) async {
    final clamped = volume.clamp(0.0, 2.0).toDouble();
    _peerVolumes[userId] = clamped;
    await _applyPeerVolume(userId);
    notifyListeners();
  }

  double getPeerVolume(int userId) => _peerVolumes[userId] ?? 1.0;

  Future<void> _applyPeerVolume(int userId) async {
    final peer = _peers[userId];
    final stream = peer?.remoteAudioStream;
    if (stream == null) return;
    final volume = _peerVolumes[userId] ?? 1.0;
    for (final track in stream.getAudioTracks()) {
      try {
        await Helper.setVolume(volume, track);
      } catch (e) {
        debugPrint('[VOICE] setVolume hatası ($userId): $e');
      }
    }
  }

  /// Discord davranışı: deafen açıkken hem gelen ses kapanır hem de
  /// kendi mikrofonun mute olur. Kapatınca eski mute durumu geri gelir.
  void toggleDeafen() {
    _deafened = !_deafened;
    _applyAudioState();
    notifyListeners();
  }

  void _applyAudioState() {
    // Kendi mikrofon: deafen veya mute aktifse kapalı
    if (_localStream != null) {
      for (final track in _localStream!.getAudioTracks()) {
        track.enabled = !_muted && !_deafened;
      }
    }
    // Gelen sesler: deafen aktifse kapalı
    for (final peer in _peers.values) {
      final stream = peer.remoteAudioStream;
      if (stream == null) continue;
      for (final track in stream.getAudioTracks()) {
        track.enabled = !_deafened;
      }
    }
  }

  Future<void> _createPeerAndOffer(int userId, String username) async {
    final peer = await _createPeer(userId, username);
    final offer = await peer.pc.createOffer({});
    await peer.pc.setLocalDescription(offer);
    _sendSignal(userId, {
      'kind': 'offer',
      'sdp': offer.sdp,
      'type': offer.type,
    });
  }

  Future<VoicePeer> _createPeer(int userId, String username) async {
    final pc = await createPeerConnection(_rtcConfig);

    // Local audio'yu ekle
    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        await pc.addTrack(track, _localStream!);
      }
    }

    // Şu an ekran paylaşıyorsak yeni peer'a da tüm track'leri (video + sistem audio) ekle
    if (_screenStream != null) {
      final senders = <RTCRtpSender>[];
      for (final track in _screenStream!.getTracks()) {
        final sender = await pc.addTrack(track, _screenStream!);
        senders.add(sender);
      }
      _screenSenders[userId] = senders;
      await _applyBitrate(senders, _lastScreenOpts.maxBitrateKbps);
    }

    // Kamera paylaşımı aktifse yeni peer'a video track'i ekle
    if (_cameraStream != null) {
      final senders = <RTCRtpSender>[];
      for (final track in _cameraStream!.getVideoTracks()) {
        final sender = await pc.addTrack(track, _cameraStream!);
        senders.add(sender);
      }
      _cameraSenders[userId] = senders;
      await _applyBitrate(senders, 2500);
    }

    final peer = VoicePeer(userId: userId, username: username, pc: pc);
    _peers[userId] = peer;

    // Input control data channel (her peer için bir tane)
    try {
      final dc = await pc.createDataChannel(
        'input',
        RTCDataChannelInit()..ordered = true,
      );
      _attachInputHandler(dc, username);
      peer.inputChannel = dc;
      debugPrint('[VOICE] Input data channel oluşturuldu: $username');
    } catch (e) {
      debugPrint('[VOICE] Data channel oluşturulamadı ($username): $e');
    }

    // Karşı taraf data channel açarsa (answerer tarafı)
    pc.onDataChannel = (RTCDataChannel channel) {
      if (channel.label == 'input') {
        _attachInputHandler(channel, username);
        peer.inputChannel = channel;
        debugPrint('[VOICE] Input data channel alındı: $username');
      }
    };

    pc.onIceCandidate = (RTCIceCandidate c) {
      _sendSignal(userId, {
        'kind': 'ice',
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    };

    pc.onTrack = (RTCTrackEvent event) {
      if (event.streams.isEmpty) return;
      final stream = event.streams.first;
      if (event.track.kind == 'audio') {
        peer.remoteAudioStream = stream;
        // Deafen aktifse yeni track'i de hemen kapat
        if (_deafened) {
          for (final t in stream.getAudioTracks()) {
            t.enabled = false;
          }
        }
        // Önceden ayarlanmış volume varsa uygula (kullanıcı reconnect olmuş olabilir)
        if (_peerVolumes.containsKey(userId)) {
          _applyPeerVolume(userId);
        }
      } else if (event.track.kind == 'video') {
        // Stream tipi: _peerStreamTypes'tan bakılır. Bilinmiyorsa 'screen' varsayılır
        // (geriye dönük uyumluluk: önceden tüm video'lar ekran paylaşımıydı).
        final typeMap = _peerStreamTypes[userId];
        final t = typeMap?[stream.id];
        final isCamera = t == 'camera';
        if (isCamera) {
          peer.remoteCameraStream = stream;
          event.track.onEnded = () {
            if (peer.remoteCameraStream == stream) {
              peer.remoteCameraStream = null;
              notifyListeners();
            }
          };
        } else {
          peer.remoteScreenStream = stream;
          event.track.onEnded = () {
            if (peer.remoteScreenStream == stream) {
              peer.remoteScreenStream = null;
              notifyListeners();
            }
          };
        }
      }
      notifyListeners();
    };

    pc.onConnectionState = (RTCPeerConnectionState state) {
      debugPrint('[VOICE] peer $username durum: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        // Otomatik temizlik yapma — sunucu zaten ayrılma bildirimi gönderecek
      }
    };

    return peer;
  }

  /// Backend'den voice-signal mesajı geldiğinde çağrılır.
  Future<void> handleSignal({
    required int fromUserId,
    required String fromUsername,
    required Map<String, dynamic> payload,
  }) async {
    final kind = payload['kind'] as String?;
    if (kind == 'offer') {
      // Karşı taraf bize offer gönderdi -> peer oluştur, answer üret
      final wasNewPeer = !_peers.containsKey(fromUserId);
      final peer = _peers[fromUserId] ??
          await _createPeer(fromUserId, fromUsername);
      await peer.pc.setRemoteDescription(
        RTCSessionDescription(
            payload['sdp'] as String, payload['type'] as String),
      );
      final answer = await peer.pc.createAnswer({});
      await peer.pc.setLocalDescription(answer);
      _sendSignal(fromUserId, {
        'kind': 'answer',
        'sdp': answer.sdp,
        'type': answer.type,
      });

      // Yeni peer durumu: B yeni katıldı, sadece kendi mikrofonunu offer'a
      // koydu. _createPeer kendi screen/audio track'lerimizi addTrack etti
      // ama bu track'ler B'nin offer SDP'sinde olmadığı için answer'da
      // düzgün yansımıyor. Renegotiate ile A→B yönünde yeni offer gönderip
      // kendi track'lerimizi expose edelim.
      // Eğer ekran/kamera paylaşımı veya audio track varsa renegotiate gerekli.
      if (wasNewPeer &&
          (_screenStream != null ||
              _cameraStream != null ||
              _localStream != null)) {
        // Answer set edildikten sonra kısa bekleme, sonra renegotiate +
        // stream-info gönder (yeni peer hangi stream'in kamera/ekran olduğunu öğrensin)
        Future.delayed(const Duration(milliseconds: 250), () async {
          // Peer hala bağlı mı kontrol et
          if (_peers[fromUserId] == peer) {
            try {
              if (_screenStream != null) {
                _sendStreamInfo(fromUserId, _screenStream!.id, 'screen');
              }
              if (_cameraStream != null) {
                _sendStreamInfo(fromUserId, _cameraStream!.id, 'camera');
              }
              await _renegotiate(peer);
              debugPrint(
                  '[VOICE] Yeni peer $fromUsername için renegotiate edildi');
            } catch (e) {
              debugPrint('[VOICE] Renegotiate hatası ($fromUsername): $e');
            }
          }
        });
      }
    } else if (kind == 'stream-info') {
      // Karşı taraf bir stream'in tipini bildirdi (camera|screen)
      final streamId = payload['streamId'] as String?;
      final streamKind = payload['streamKind'] as String?;
      if (streamId != null && streamKind != null) {
        final map = _peerStreamTypes.putIfAbsent(fromUserId, () => {});
        map[streamId] = streamKind;
        // Track halihazırda geldiyse yanlış kategoride olabilir — düzelt
        final peer = _peers[fromUserId];
        if (peer != null) {
          if (streamKind == 'camera' &&
              peer.remoteScreenStream?.id == streamId) {
            peer.remoteCameraStream = peer.remoteScreenStream;
            peer.remoteScreenStream = null;
            notifyListeners();
          } else if (streamKind == 'screen' &&
              peer.remoteCameraStream?.id == streamId) {
            peer.remoteScreenStream = peer.remoteCameraStream;
            peer.remoteCameraStream = null;
            notifyListeners();
          }
        }
      }
    } else if (kind == 'answer') {
      final peer = _peers[fromUserId];
      if (peer != null) {
        await peer.pc.setRemoteDescription(
          RTCSessionDescription(payload['sdp'] as String, payload['type'] as String),
        );
      }
    } else if (kind == 'ice') {
      final peer = _peers[fromUserId];
      if (peer != null) {
        final candidate = RTCIceCandidate(
          payload['candidate'] as String?,
          payload['sdpMid'] as String?,
          payload['sdpMLineIndex'] as int?,
        );
        await peer.pc.addCandidate(candidate);
      }
    }
  }

  /// Input data channel'e gelen mesajları dinle ve onInputEvent callback'ini çağır.
  void _attachInputHandler(RTCDataChannel channel, String username) {
    channel.onMessage = (RTCDataChannelMessage msg) {
      final text = msg.text;
      if (text != null) {
        try {
          final event = jsonDecode(text) as Map<String, dynamic>;
          onInputEvent?.call(event);
        } catch (e) {
          debugPrint('[VOICE] Input event parse hatası ($username): $e');
        }
      }
    };
  }

  /// Uzak peer'a input event gönder (fare/klavye).
  /// Sadece ekran paylaşımı olan peer'a gönderir.
  void sendInputEvent(int targetUserId, Map<String, dynamic> event) {
    final peer = _peers[targetUserId];
    if (peer == null) return;
    final dc = peer.inputChannel;
    if (dc == null || dc.state != RTCDataChannelState.RTCDataChannelOpen) return;
    try {
      dc.send(RTCDataChannelMessage(jsonEncode(event)));
    } catch (e) {
      debugPrint('[VOICE] Input event gönderilemedi ($targetUserId): $e');
    }
  }

  /// Kontrol edilen peer'i ayarla (UI'dan çağrılır).
  void setControllingPeer(int? userId) {
    _controllingPeerId = userId;
    notifyListeners();
  }

  int? get controllingPeerId => _controllingPeerId;

  /// Kanaldaki üye listesi güncellendiğinde çağrılır.
  /// Bizim olduğumuz kanaldaki listeden kaybolanların peer'ını kapatır.
  Future<void> syncMembers(int channelId, List<int> currentUserIds) async {
    if (_currentChannelId != channelId) return;
    final toClose = _peers.keys.where((id) => !currentUserIds.contains(id)).toList();
    for (final id in toClose) {
      await _closePeer(id);
    }
  }

  Future<void> _closePeer(int userId) async {
    final peer = _peers.remove(userId);
    _screenSenders.remove(userId);
    _cameraSenders.remove(userId);
    _peerStreamTypes.remove(userId);
    if (peer == null) return;
    try {
      peer.inputChannel?.close();
    } catch (_) {}
    await peer.pc.close();
    if (_controllingPeerId == userId) _controllingPeerId = null;
    notifyListeners();
  }

  @override
  void dispose() {
    leave();
    super.dispose();
  }
}
