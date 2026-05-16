import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Bildirim seslerini yöneten servis.
///
/// - playMessage(): Yeni mesaj geldiğinde (mevcut kanal değilse veya pencere
///   arkadaysa) çalınacak kısa "ding".
/// - playUserJoinedVoice(): Bir başkası sesli kanala katıldığında.
/// - playUserLeftVoice(): Bir başkası sesli kanaldan ayrıldığında.
/// - playSelfJoined(): Kendin sesli kanala katıldığında.
/// - playSelfLeft(): Kendin sesli kanaldan ayrıldığında.
///
/// Her ses tipinin kendi AudioPlayer'ı vardır — aynı anda birden fazla ses
/// çalabilir (örn. mesaj + katılım).
class SoundService {
  static final SoundService _instance = SoundService._();
  factory SoundService() => _instance;

  final _message = AudioPlayer();
  final _userJoined = AudioPlayer();
  final _userLeft = AudioPlayer();
  final _selfJoined = AudioPlayer();
  final _selfLeft = AudioPlayer();
  final _shareStarted = AudioPlayer();
  final _shareStopped = AudioPlayer();

  bool enabled = true;

  SoundService._() {
    // Her oyuncu için release mode: stop (low-latency, no streaming)
    for (final p in [
      _message,
      _userJoined,
      _userLeft,
      _selfJoined,
      _selfLeft,
      _shareStarted,
      _shareStopped,
    ]) {
      p.setReleaseMode(ReleaseMode.stop);
    }
  }

  Future<void> _play(AudioPlayer player, String asset) async {
    if (!enabled) return;
    try {
      await player.stop();
      await player.play(AssetSource(asset));
    } catch (e) {
      debugPrint('[SOUND] $asset çalınamadı: $e');
    }
  }

  Future<void> playMessage() => _play(_message, 'sounds/message.wav');
  Future<void> playUserJoinedVoice() =>
      _play(_userJoined, 'sounds/user_joined.wav');
  Future<void> playUserLeftVoice() =>
      _play(_userLeft, 'sounds/user_left.wav');
  Future<void> playSelfJoined() =>
      _play(_selfJoined, 'sounds/self_joined.wav');
  Future<void> playSelfLeft() => _play(_selfLeft, 'sounds/self_left.wav');
  Future<void> playShareStarted() =>
      _play(_shareStarted, 'sounds/share_started.wav');
  Future<void> playShareStopped() =>
      _play(_shareStopped, 'sounds/share_stopped.wav');

  Future<void> dispose() async {
    for (final p in [
      _message,
      _userJoined,
      _userLeft,
      _selfJoined,
      _selfLeft,
      _shareStarted,
      _shareStopped,
    ]) {
      try {
        await p.dispose();
      } catch (_) {}
    }
  }
}
