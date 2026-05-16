import 'package:flutter/material.dart';
import '../config.dart';

/// Tüm uygulamada kullanılan kullanıcı avatarı.
///
/// `avatarUrl` varsa server'dan resmi gösterir; yoksa kullanıcı adının
/// baş harfi ile renkli daire gösterir. `online` non-null verilirse
/// sağ alt köşeye durum göstergesi (yeşil=online, gri=offline) eklenir.
class UserAvatar extends StatelessWidget {
  final String username;
  final String? avatarUrl;
  final double radius;
  final Color? backgroundColor;
  final bool? online;
  final Color statusBorderColor;
  /// true ise avatar'ın etrafına yeşil parlama ring'i çizilir
  final bool speaking;

  const UserAvatar({
    super.key,
    required this.username,
    this.avatarUrl,
    this.radius = 20,
    this.backgroundColor,
    this.online,
    this.statusBorderColor = const Color(0xFF202225),
    this.speaking = false,
  });

  String get _initials {
    if (username.isEmpty) return '?';
    final parts = username.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts[1][0]).toUpperCase();
  }

  static const _palette = [
    Color(0xFFED4245),
    Color(0xFF5865F2),
    Color(0xFF3BA55D),
    Color(0xFFFAA61A),
    Color(0xFFEB459E),
    Color(0xFF00AFF4),
  ];

  Color get _fallbackColor {
    if (username.isEmpty) return _palette[0];
    return _palette[username.hashCode.abs() % _palette.length];
  }

  ImageProvider? get _image {
    if (avatarUrl == null || avatarUrl!.isEmpty) return null;
    final url = avatarUrl!.startsWith('http')
        ? avatarUrl!
        : '${Config.httpBase}$avatarUrl';
    return NetworkImage(url);
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    final innerAvatar = CircleAvatar(
      radius: radius,
      backgroundColor: backgroundColor ?? _fallbackColor,
      backgroundImage: img,
      child: img == null
          ? Text(
              _initials,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: radius * 0.8,
              ),
            )
          : null,
    );

    // Konuşma ring'i — Discord stili yeşil parlama
    final avatar = speaking
        ? Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF3BA55D).withValues(alpha: 0.85),
                  blurRadius: 8,
                  spreadRadius: 1.5,
                ),
              ],
              border: Border.all(
                color: const Color(0xFF3BA55D),
                width: 2,
              ),
            ),
            child: innerAvatar,
          )
        : innerAvatar;

    if (online == null) return avatar;

    final dotSize = (radius * 0.5).clamp(8.0, 16.0);
    final borderWidth = (radius * 0.12).clamp(1.5, 3.0);
    return SizedBox(
      width: radius * 2,
      height: radius * 2,
      child: Stack(
        children: [
          avatar,
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: dotSize,
              height: dotSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: online!
                    ? const Color(0xFF3BA55D) // Discord yeşili (online)
                    : const Color(0xFF747F8D), // Discord grisi (offline)
                border: Border.all(
                  color: statusBorderColor,
                  width: borderWidth,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
