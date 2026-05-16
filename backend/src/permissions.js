// Discord-stili permission bit flags.
// Roller bu bit'leri toplayarak permission set'i oluştururlar.
const PERMISSIONS = {
  MANAGE_SERVER: 1 << 0, // Sunucu adı, davet, sil
  MANAGE_ROLES: 1 << 1, // Rol oluştur/sil/düzenle + üye-rol ata
  MANAGE_CHANNELS: 1 << 2, // Kanal oluştur/sil/yeniden adlandır
  MANAGE_MESSAGES: 1 << 3, // Diğerlerinin mesajlarını sil
  KICK_MEMBERS: 1 << 4, // Üyeyi sunucudan at
  VIEW_CHANNELS: 1 << 5, // Kanal listesini ve mesajları gör
  SEND_MESSAGES: 1 << 6, // Mesaj gönder
  CONNECT_VOICE: 1 << 7, // Sesli kanala katıl
  SPEAK_VOICE: 1 << 8, // Sesli kanalda konuş (mikrofon aç)
  SCREEN_SHARE: 1 << 9, // Ekran paylaş
  MENTION_EVERYONE: 1 << 10, // @everyone bildirimi
};

const ALL_PERMISSIONS = Object.values(PERMISSIONS).reduce(
  (a, b) => a | b,
  0
);

// Default '@everyone' rolü — sunucuya yeni üye geldiğinde otomatik atanır.
// Konuşma + ses + ekran paylaşımı varsayılan, yönetim yetkileri yok.
const DEFAULT_EVERYONE_PERMS =
  PERMISSIONS.VIEW_CHANNELS |
  PERMISSIONS.SEND_MESSAGES |
  PERMISSIONS.CONNECT_VOICE |
  PERMISSIONS.SPEAK_VOICE |
  PERMISSIONS.SCREEN_SHARE;

// Hazır 'Admin' rolü preset'i — owner tarafından üyelere verilir
const DEFAULT_ADMIN_PERMS = ALL_PERMISSIONS;

function permissionNames() {
  return Object.keys(PERMISSIONS);
}

function permFromName(name) {
  return PERMISSIONS[name] || 0;
}

function hasFlag(permissions, flag) {
  return (permissions & flag) === flag;
}

module.exports = {
  PERMISSIONS,
  ALL_PERMISSIONS,
  DEFAULT_EVERYONE_PERMS,
  DEFAULT_ADMIN_PERMS,
  permissionNames,
  permFromName,
  hasFlag,
};
