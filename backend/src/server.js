const express = require('express');
const cors = require('cors');
const http = require('http');
const os = require('os');
const path = require('path');
const fs = require('fs');
const multer = require('multer');
const { WebSocketServer } = require('ws');
const db = require('./db');
const {
  register,
  login,
  loginByUsername,
  verifyToken,
  getUserById,
  updateProfile,
  setUserAvatar,
} = require('./auth');
const {
  PERMISSIONS,
  ALL_PERMISSIONS,
  permissionNames,
  hasFlag,
} = require('./permissions');

const app = express();
app.use(cors());
app.use(express.json());

// Avatar yükleme klasörü
const uploadsDir = path.join(__dirname, '..', 'uploads');
if (!fs.existsSync(uploadsDir)) {
  fs.mkdirSync(uploadsDir, { recursive: true });
}
app.use('/uploads', express.static(uploadsDir));

// Avatar yükleme yapılandırması (5 MB limit, sadece resim)
const ALLOWED_IMAGE_EXTS = new Set(['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp']);

const avatarUpload = multer({
  storage: multer.diskStorage({
    destination: uploadsDir,
    filename: (req, file, cb) => {
      const safeExt = (path.extname(file.originalname) || '.png')
        .toLowerCase()
        .replace(/[^a-z0-9.]/g, '');
      cb(null, `avatar_${req.user.userId}_${Date.now()}${safeExt}`);
    },
  }),
  limits: { fileSize: 5 * 1024 * 1024 },
  fileFilter: (_req, file, cb) => {
    const isImageMime = /^image\//.test(file.mimetype || '');
    const ext = path.extname(file.originalname || '').toLowerCase();
    const isImageExt = ALLOWED_IMAGE_EXTS.has(ext);
    // MIME tipi veya uzantısı kabul edilen resim formatına uyuyorsa onayla
    if (isImageMime || isImageExt) {
      return cb(null, true);
    }
    return cb(new Error('Sadece resim dosyaları yüklenebilir (jpg, png, webp, gif, bmp)'));
  },
});

app.get('/', (_req, res) => {
  res.json({ ok: true, name: 'localhub-backend' });
});

/// Backend cihazinin Radmin VPN (26.x.x.x) IP adresini doner.
/// Bulamazsa diger 10/192.168 ozel araliklara dusulur; yine bulunamazsa null.
/// Bu deger, login eden kullanicinin "host makinesinde mi" kontrolu icin
/// kullanilir — host ise default sunucunun owner'i yapilir.
function detectHostRadminIp() {
  const interfaces = os.networkInterfaces();
  let radmin = null;
  let fallback = null;
  for (const addrs of Object.values(interfaces)) {
    if (!addrs) continue;
    for (const addr of addrs) {
      if (addr.family !== 'IPv4' || addr.internal) continue;
      if (addr.address.startsWith('26.')) {
        radmin = addr.address;
        break;
      }
      // Fallback olarak ilk LAN IP'si (Radmin yoksa)
      fallback ??= addr.address;
    }
    if (radmin) break;
  }
  return radmin ?? fallback;
}

const HOST_RADMIN_IP = detectHostRadminIp();
console.log(`[BACKEND] Tespit edilen host Radmin/LAN IP: ${HOST_RADMIN_IP ?? '(bulunamadi)'}`);

/// Gelen istegin host makinesinden mi geldigini soyler.
/// Localhost veya backend'in kendi Radmin IP'sinden gelen istek = host.
function isRequestFromHost(req) {
  const raw = (req.ip || req.connection?.remoteAddress || '').toString();
  // IPv4-mapped IPv6 prefix'ini sil (::ffff:127.0.0.1 -> 127.0.0.1)
  const ip = raw.replace(/^::ffff:/, '');
  if (ip === '127.0.0.1' || ip === '::1' || ip === 'localhost') return true;
  if (HOST_RADMIN_IP && ip === HOST_RADMIN_IP) return true;
  return false;
}

/// Bir kullaniciyi default sunucunun owner'i yap:
/// - servers.owner_user_id'i guncelle
/// - server_members.role = 'owner' yap
/// - Admin rolunu ata
function promoteUserToOwner(userId) {
  try {
    db.prepare('UPDATE servers SET owner_user_id = ? WHERE id = 1').run(userId);
    db.prepare(
      "UPDATE server_members SET role = 'owner' WHERE server_id = 1 AND user_id = ?"
    ).run(userId);
    const adminRole = db
      .prepare("SELECT id FROM roles WHERE server_id = 1 AND name = 'Admin'")
      .get();
    if (adminRole) {
      db.prepare(
        'INSERT OR IGNORE INTO user_roles (server_id, user_id, role_id, assigned_at) VALUES (1, ?, ?, ?)'
      ).run(userId, adminRole.id, Date.now());
    }
    console.log(`[BACKEND] User ${userId} default sunucuya owner yapildi (host IP esleme)`);
  } catch (err) {
    console.error('[BACKEND] promoteUserToOwner hata:', err.message);
  }
}

/// Sadece username ile giriş. Yeni kullanıcıysa otomatik oluşturur,
/// default sunucuya üye yapar. Şifre/email yok.
///
/// Bonus: Eger istek host makinesinden geliyorsa (localhost veya backend'in
/// kendi Radmin IP'si) VE default sunucunun henuz gercek bir owner'i yoksa,
/// bu kullaniciyi otomatik olarak owner/admin yapar.
async function loginAndJoinDefault(req, res) {
  try {
    const { username } = req.body || {};
    const result = await loginByUsername(username);
    // Default sunucuya üye yap (yoksa)
    try {
      db.prepare(
        'INSERT OR IGNORE INTO server_members (server_id, user_id, role, joined_at) VALUES (1, ?, ?, ?)'
      ).run(result.user.id, 'member', Date.now());
      // @everyone rolünü ata
      const everyone = db.prepare(
        'SELECT id FROM roles WHERE server_id = 1 AND is_default = 1'
      ).get();
      if (everyone) {
        db.prepare(
          'INSERT OR IGNORE INTO user_roles (server_id, user_id, role_id, assigned_at) VALUES (1, ?, ?, ?)'
        ).run(result.user.id, everyone.id, Date.now());
      }

      // Host makinesinden gelen ilk login'i sunucunun sahibi yap.
      // (owner_user_id = 0 zero-state placeholder; veya yine ayni host
      //  makinesinden gelen istek)
      if (isRequestFromHost(req)) {
        const srv = db
          .prepare('SELECT owner_user_id FROM servers WHERE id = 1')
          .get();
        // Owner henuz atanmamis (0 placeholder) → host login = owner
        if (srv && (!srv.owner_user_id || srv.owner_user_id === 0)) {
          promoteUserToOwner(result.user.id);
        }
        // Owner zaten varsa, ayni host'tan farkli username ile login olunduysa
        // (kullanici nick degistirmis veya yeni hesap acmis) — yine de owner yap.
        // Çünkü host makinesi sahibi her zaman admin olmali.
        else if (srv && srv.owner_user_id !== result.user.id) {
          // Sadece "henuz hic owner login olmadı" gibi durumda devret;
          // aksi halde mevcut owner korunur. Bu else dali simdilik no-op.
        }
      }
    } catch (e) {
      console.error('[BACKEND] loginAndJoinDefault membership hata:', e.message);
    }
    broadcastUserListUpdated();
    res.json(result);
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
}

// Hem /api/login hem /api/register username-only login'e yönlendirir
app.post('/api/login', loginAndJoinDefault);
app.post('/api/register', loginAndJoinDefault);

// JWT auth middleware (route bazlı)
function authRequired(req, res, next) {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  const payload = token ? verifyToken(token) : null;
  if (!payload) return res.status(401).json({ error: 'Yetkisiz' });
  req.user = payload; // { userId, username }
  next();
}

/// Yetkilendirme gerektirmeyen sunucu sağlık/keşif endpoint'i.
/// Login öncesi ping testi ve "sunucuya ulaşılabilir mi" kontrolü için.
app.get('/api/health', (_req, res) => {
  res.json({
    ok: true,
    name: 'LocalHub',
    version: '1.0.0',
    time: Date.now(),
  });
});

/// Yetkilendirme gerektirmeyen "şu an online kim?" endpoint'i.
/// Login ekranındaki sunucu listesi her sunucunun aktif kullanıcılarını
/// göstermek için bu endpoint'i kullanır. Şifre/email vs hassas veri
/// dönmez — yalnızca id + username + avatar_url.
app.get('/api/public/online-users', (_req, res) => {
  try {
    // WS oturumlarındaki userId'leri topla
    const onlineIds = new Set();
    for (const info of clients.values()) {
      onlineIds.add(info.userId);
    }
    if (onlineIds.size === 0) {
      return res.json({ users: [] });
    }
    const placeholders = Array.from(onlineIds).map(() => '?').join(',');
    const rows = db
      .prepare(
        `SELECT id, username, avatar_url FROM users WHERE id IN (${placeholders}) ORDER BY username COLLATE NOCASE`
      )
      .all(...Array.from(onlineIds));
    res.json({ users: rows });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Auto-updater artık GitHub Releases tabanlı — backend endpoint'i yok.
// App doğrudan api.github.com'dan latest release manifest'ini çeker.

app.get('/api/me', authRequired, (req, res) => {
  const user = getUserById(req.user.userId);
  if (!user) return res.status(404).json({ error: 'Kullanıcı bulunamadı' });
  res.json(user);
});

app.post(
  '/api/me/avatar',
  authRequired,
  (req, res, next) => {
    avatarUpload.single('avatar')(req, res, (err) => {
      if (err) return res.status(400).json({ error: err.message });
      next();
    });
  },
  (req, res) => {
    if (!req.file) {
      return res.status(400).json({ error: 'Dosya gerekli' });
    }
    // Eski avatar'ı sil (varsa)
    const old = getUserById(req.user.userId);
    if (old && old.avatar_url) {
      const oldName = old.avatar_url.replace(/^\/uploads\//, '');
      const oldPath = path.join(uploadsDir, oldName);
      fs.unlink(oldPath, () => {});
    }
    const avatarUrl = `/uploads/${req.file.filename}`;
    const updated = setUserAvatar(req.user.userId, avatarUrl);
    broadcastUserProfileUpdated(updated);
    res.json(updated);
  }
);

app.delete('/api/me/avatar', authRequired, (req, res) => {
  const user = getUserById(req.user.userId);
  if (user && user.avatar_url) {
    const name = user.avatar_url.replace(/^\/uploads\//, '');
    fs.unlink(path.join(uploadsDir, name), () => {});
  }
  const updated = setUserAvatar(req.user.userId, null);
  broadcastUserProfileUpdated(updated);
  res.json(updated);
});

app.patch('/api/me', authRequired, async (req, res) => {
  try {
    const { username, email, password, currentPassword } = req.body || {};
    const updated = await updateProfile(req.user.userId, {
      username,
      email,
      password,
      currentPassword,
    });
    // Username değişmiş olabilir - voice members'da güncellemek için yayın yap
    broadcastUserProfileUpdated(updated);
    res.json(updated);
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

// ============================================================
// SUNUCU (TENANT) ENDPOINT'LERİ
// ============================================================

function generateInviteCode() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  let code = '';
  for (let i = 0; i < 8; i++) {
    code += chars[Math.floor(Math.random() * chars.length)];
  }
  return code;
}

function isServerMember(serverId, userId) {
  const row = db
    .prepare(
      'SELECT 1 FROM server_members WHERE server_id = ? AND user_id = ?'
    )
    .get(serverId, userId);
  return !!row;
}

function getUserRole(serverId, userId) {
  const row = db
    .prepare(
      'SELECT role FROM server_members WHERE server_id = ? AND user_id = ?'
    )
    .get(serverId, userId);
  return row ? row.role : null;
}

// Rol hiyerarşisi: owner > admin > member
function roleRank(role) {
  if (role === 'owner') return 2;
  if (role === 'admin') return 1;
  if (role === 'member') return 0;
  return -1; // üye değil
}

function hasMinRole(serverId, userId, minRole) {
  const role = getUserRole(serverId, userId);
  return roleRank(role) >= roleRank(minRole);
}

/// Kullanıcının bir sunucudaki toplam permission bit'lerini hesapla.
/// Owner ise her zaman ALL_PERMISSIONS. Aksi takdirde @everyone + atanmış
/// custom roller permission'larının union'u (OR).
function computeUserPermissions(serverId, userId) {
  const member = db
    .prepare(
      'SELECT role FROM server_members WHERE server_id = ? AND user_id = ?'
    )
    .get(serverId, userId);
  if (!member) return 0;
  if (member.role === 'owner') return ALL_PERMISSIONS;

  // @everyone (default) rolü her üyeye otomatik uygulanır
  let perms = 0;
  const everyone = db
    .prepare(
      'SELECT permissions FROM roles WHERE server_id = ? AND is_default = 1'
    )
    .get(serverId);
  if (everyone) perms |= everyone.permissions;

  // Atanmış custom rollerin permission'ları
  const userRoles = db
    .prepare(
      `SELECT r.permissions FROM user_roles ur
       JOIN roles r ON r.id = ur.role_id
       WHERE ur.server_id = ? AND ur.user_id = ?`
    )
    .all(serverId, userId);
  for (const r of userRoles) perms |= r.permissions;

  return perms;
}

function hasPermission(serverId, userId, permission) {
  return hasFlag(computeUserPermissions(serverId, userId), permission);
}

/// Kullanicinin belirli bir KANAL icin gecerli toplam izin bit'leri.
/// Discord-stili allow/deny override modeli:
///   base = sunucu seviyesindeki computeUserPermissions
///   her rol icin (her kullanicinin rolleri) channel_role_overrides'i topla
///   final = (base & ~deny_union) | allow_union
/// Owner = ALL_PERMISSIONS (bypass).
function computeUserChannelPermissions(channelId, userId) {
  const ch = db
    .prepare('SELECT server_id FROM channels WHERE id = ?')
    .get(channelId);
  if (!ch) return 0;
  const serverId = ch.server_id;

  const member = db
    .prepare(
      'SELECT role FROM server_members WHERE server_id = ? AND user_id = ?'
    )
    .get(serverId, userId);
  if (!member) return 0;
  if (member.role === 'owner') return ALL_PERMISSIONS;

  // Sunucu seviyesindeki base izinler
  const base = computeUserPermissions(serverId, userId);

  // Kullanicinin sahip oldugu tum rol id'leri (@everyone dahil)
  const roleIds = new Set();
  const everyone = db
    .prepare(
      'SELECT id FROM roles WHERE server_id = ? AND is_default = 1'
    )
    .get(serverId);
  if (everyone) roleIds.add(everyone.id);
  const userRoles = db
    .prepare(
      'SELECT role_id FROM user_roles WHERE server_id = ? AND user_id = ?'
    )
    .all(serverId, userId);
  for (const r of userRoles) roleIds.add(r.role_id);

  if (roleIds.size === 0) return base;

  // Bu kullanicinin sahip oldugu rolleler icin kanal override'larini topla
  const placeholders = Array.from(roleIds).map(() => '?').join(',');
  const overrides = db
    .prepare(
      `SELECT allow_perms, deny_perms FROM channel_role_overrides
       WHERE channel_id = ? AND role_id IN (${placeholders})`
    )
    .all(channelId, ...Array.from(roleIds));

  let allowUnion = 0;
  let denyUnion = 0;
  for (const o of overrides) {
    allowUnion |= o.allow_perms;
    denyUnion |= o.deny_perms;
  }
  return (base & ~denyUnion) | allowUnion;
}

function hasChannelPermission(channelId, userId, permission) {
  return hasFlag(computeUserChannelPermissions(channelId, userId), permission);
}

// Kullanıcının üye olduğu sunucular
app.get('/api/servers', authRequired, (req, res) => {
  const list = db
    .prepare(
      `SELECT s.id, s.name, s.owner_user_id, s.invite_code, s.created_at,
              sm.role AS my_role
       FROM servers s
       JOIN server_members sm ON sm.server_id = s.id
       WHERE sm.user_id = ?
       ORDER BY sm.joined_at ASC`
    )
    .all(req.user.userId);
  // Her sunucuda kullanıcının hesaplanan permission'ları
  const out = list.map((s) => ({
    ...s,
    my_permissions: computeUserPermissions(s.id, req.user.userId),
  }));
  res.json(out);
});

// Yeni sunucu oluştur (oluşturan = owner)
app.post('/api/servers', authRequired, (req, res) => {
  try {
    const { name } = req.body || {};
    const trimmed = (name || '').toString().trim();
    if (trimmed.length < 1 || trimmed.length > 50) {
      return res.status(400).json({ error: 'Sunucu adı 1-50 karakter olmalı' });
    }
    const now = Date.now();
    const inviteCode = generateInviteCode();
    const result = db
      .prepare(
        'INSERT INTO servers (name, owner_user_id, invite_code, created_at) VALUES (?, ?, ?, ?)'
      )
      .run(trimmed, req.user.userId, inviteCode, now);
    const serverId = result.lastInsertRowid;
    // Kurucuyu owner olarak ekle
    db.prepare(
      'INSERT INTO server_members (server_id, user_id, role, joined_at) VALUES (?, ?, ?, ?)'
    ).run(serverId, req.user.userId, 'owner', now);
    // Default kanallar
    const defaultChannels = [
      { name: 'genel', type: 'text' },
      { name: 'sesli-oda', type: 'voice' },
    ];
    const insChannel = db.prepare(
      'INSERT INTO channels (server_id, name, type, created_at) VALUES (?, ?, ?, ?)'
    );
    for (const c of defaultChannels) {
      insChannel.run(serverId, c.name, c.type, now);
    }
    // Default @everyone + Admin rolleri (server oluşturulduktan sonra)
    const insertRole = db.prepare(
      `INSERT INTO roles (server_id, name, color, permissions, position, is_default, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`
    );
    const { DEFAULT_EVERYONE_PERMS, DEFAULT_ADMIN_PERMS } =
      require('./permissions');
    insertRole.run(
      serverId,
      '@everyone',
      '#99AAB5',
      DEFAULT_EVERYONE_PERMS,
      0,
      1,
      now
    );
    insertRole.run(
      serverId,
      'Admin',
      '#ED4245',
      DEFAULT_ADMIN_PERMS,
      100,
      0,
      now
    );

    res.json({
      id: serverId,
      name: trimmed,
      owner_user_id: req.user.userId,
      invite_code: inviteCode,
      created_at: now,
      my_role: 'owner',
      my_permissions: ALL_PERMISSIONS,
    });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Invite code ile sunucuya katıl
app.post('/api/servers/join', authRequired, (req, res) => {
  try {
    const { invite_code } = req.body || {};
    const code = (invite_code || '').toString().trim().toLowerCase();
    if (!code) return res.status(400).json({ error: 'Davet kodu gerekli' });
    const server = db
      .prepare('SELECT * FROM servers WHERE invite_code = ?')
      .get(code);
    if (!server) return res.status(404).json({ error: 'Davet kodu geçersiz' });
    if (isServerMember(server.id, req.user.userId)) {
      return res.status(400).json({ error: 'Zaten bu sunucunun üyesisin' });
    }
    db.prepare(
      'INSERT INTO server_members (server_id, user_id, role, joined_at) VALUES (?, ?, ?, ?)'
    ).run(server.id, req.user.userId, 'member', Date.now());
    res.json({
      id: server.id,
      name: server.name,
      owner_user_id: server.owner_user_id,
      invite_code: server.invite_code,
      created_at: server.created_at,
      my_role: 'member',
      my_permissions: computeUserPermissions(server.id, req.user.userId),
    });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Bir üyenin rolünü değiştir (sadece owner yapabilir)
app.patch(
  '/api/servers/:serverId/members/:userId/role',
  authRequired,
  (req, res) => {
    try {
      const serverId = Number(req.params.serverId);
      const targetUserId = Number(req.params.userId);
      const { role } = req.body || {};
      if (role !== 'admin' && role !== 'member') {
        return res.status(400).json({ error: 'Geçersiz rol' });
      }
      const myRole = getUserRole(serverId, req.user.userId);
      if (myRole !== 'owner') {
        return res
          .status(403)
          .json({ error: 'Sadece sunucu sahibi rol değiştirebilir' });
      }
      const targetRole = getUserRole(serverId, targetUserId);
      if (!targetRole) {
        return res.status(404).json({ error: 'Üye bulunamadı' });
      }
      if (targetRole === 'owner') {
        return res
          .status(400)
          .json({ error: 'Sahibin rolü değiştirilemez' });
      }
      db.prepare(
        'UPDATE server_members SET role = ? WHERE server_id = ? AND user_id = ?'
      ).run(role, serverId, targetUserId);
      res.json({ ok: true, server_id: serverId, user_id: targetUserId, role });
    } catch (e) {
      res.status(500).json({ error: e.message });
    }
  }
);

// Sunucudan ayrıl (owner ayrılamaz, sunucuyu silmesi gerekir)
app.delete('/api/servers/:id/members/me', authRequired, (req, res) => {
  const serverId = Number(req.params.id);
  const role = getUserRole(serverId, req.user.userId);
  if (!role) return res.status(404).json({ error: 'Bu sunucuda değilsin' });
  if (role === 'owner') {
    return res
      .status(400)
      .json({ error: 'Sahibi sunucudan ayrılamaz; sunucuyu silebilirsin' });
  }
  db.prepare(
    'DELETE FROM server_members WHERE server_id = ? AND user_id = ?'
  ).run(serverId, req.user.userId);
  res.json({ ok: true });
});

app.get('/api/users', authRequired, (_req, res) => {
  const users = db
    .prepare(
      'SELECT id, username, email, avatar_url, virtual_ip FROM users ORDER BY username COLLATE NOCASE'
    )
    .all();
  res.json(users);
});

// Server'a özel kanal listesi (sadece kullanicinin VIEW_CHANNELS yetkisine
// sahip oldugu kanallar — owner/manageChannels'li kullanicilar tum kanallari gorur)
app.get('/api/servers/:serverId/channels', authRequired, (req, res) => {
  const serverId = Number(req.params.serverId);
  if (!isServerMember(serverId, req.user.userId)) {
    return res.status(403).json({ error: 'Bu sunucunun üyesi değilsin' });
  }
  const all = db
    .prepare(
      'SELECT id, server_id, name, type FROM channels WHERE server_id = ? ORDER BY type DESC, id'
    )
    .all(serverId);
  // MANAGE_CHANNELS yetkisi olan herseyi gorur (admin tum kanallari listeleyebilsin)
  const canManageAll = hasPermission(serverId, req.user.userId, PERMISSIONS.MANAGE_CHANNELS);
  const visible = canManageAll
    ? all
    : all.filter((c) =>
        hasChannelPermission(c.id, req.user.userId, PERMISSIONS.VIEW_CHANNELS)
      );
  res.json(visible);
});

// ============================================================
// ROL (PERMISSION) ENDPOINT'LERİ
// ============================================================

// Permission isimlerini Flutter'a göstermek için
app.get('/api/permissions', authRequired, (_req, res) => {
  res.json({
    permissions: Object.entries(PERMISSIONS).map(([name, bit]) => ({
      name,
      bit,
    })),
  });
});

// Server'ın rollerini listele
app.get('/api/servers/:serverId/roles', authRequired, (req, res) => {
  const serverId = Number(req.params.serverId);
  if (!isServerMember(serverId, req.user.userId)) {
    return res.status(403).json({ error: 'Bu sunucunun üyesi değilsin' });
  }
  const roles = db
    .prepare(
      `SELECT id, server_id, name, color, permissions, position, is_default
       FROM roles WHERE server_id = ?
       ORDER BY position DESC, id ASC`
    )
    .all(serverId);
  res.json(roles);
});

// Yeni rol oluştur (MANAGE_ROLES yetkisi gerekli)
app.post('/api/servers/:serverId/roles', authRequired, (req, res) => {
  try {
    const serverId = Number(req.params.serverId);
    if (!hasPermission(serverId, req.user.userId, PERMISSIONS.MANAGE_ROLES)) {
      return res.status(403).json({ error: 'Rol yönetme yetkin yok' });
    }
    const { name, color, permissions } = req.body || {};
    const cleanName = (name || '').toString().trim();
    if (cleanName.length < 1 || cleanName.length > 50) {
      return res.status(400).json({ error: 'Rol adı 1-50 karakter olmalı' });
    }
    if (cleanName === '@everyone') {
      return res.status(400).json({ error: 'Bu isim ayrılmış' });
    }
    const cleanColor = typeof color === 'string' && /^#[0-9A-Fa-f]{6}$/.test(color)
      ? color
      : '#99AAB5';
    const perms = Math.max(
      0,
      Math.min(ALL_PERMISSIONS, Number(permissions) || 0)
    );
    const now = Date.now();
    const result = db
      .prepare(
        `INSERT INTO roles (server_id, name, color, permissions, position, is_default, created_at)
         VALUES (?, ?, ?, ?, ?, 0, ?)`
      )
      .run(serverId, cleanName, cleanColor, perms, 1, now);
    res.json({
      id: result.lastInsertRowid,
      server_id: serverId,
      name: cleanName,
      color: cleanColor,
      permissions: perms,
      position: 1,
      is_default: 0,
    });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Rol güncelle
app.patch('/api/roles/:roleId', authRequired, (req, res) => {
  try {
    const roleId = Number(req.params.roleId);
    const role = db
      .prepare('SELECT * FROM roles WHERE id = ?')
      .get(roleId);
    if (!role) return res.status(404).json({ error: 'Rol bulunamadı' });
    if (!hasPermission(role.server_id, req.user.userId, PERMISSIONS.MANAGE_ROLES)) {
      return res.status(403).json({ error: 'Yetkisiz' });
    }
    const { name, color, permissions } = req.body || {};
    const updates = {};
    if (name !== undefined) {
      const cleanName = (name || '').toString().trim();
      if (cleanName.length < 1 || cleanName.length > 50) {
        return res.status(400).json({ error: 'Rol adı 1-50 karakter olmalı' });
      }
      if (role.is_default) {
        return res.status(400).json({ error: '@everyone rolü yeniden adlandırılamaz' });
      }
      updates.name = cleanName;
    }
    if (color !== undefined) {
      if (typeof color !== 'string' || !/^#[0-9A-Fa-f]{6}$/.test(color)) {
        return res.status(400).json({ error: 'Renk hex formatında olmalı (#RRGGBB)' });
      }
      updates.color = color;
    }
    if (permissions !== undefined) {
      updates.permissions = Math.max(
        0,
        Math.min(ALL_PERMISSIONS, Number(permissions) || 0)
      );
    }
    if (Object.keys(updates).length === 0) return res.json({ ok: true });
    const setParts = Object.keys(updates).map((k) => `${k} = ?`).join(', ');
    const values = Object.values(updates);
    db.prepare(`UPDATE roles SET ${setParts} WHERE id = ?`).run(...values, roleId);
    res.json({ ok: true, ...updates });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Rol sil
app.delete('/api/roles/:roleId', authRequired, (req, res) => {
  try {
    const roleId = Number(req.params.roleId);
    const role = db
      .prepare('SELECT * FROM roles WHERE id = ?')
      .get(roleId);
    if (!role) return res.status(404).json({ error: 'Rol bulunamadı' });
    if (role.is_default) {
      return res.status(400).json({ error: '@everyone rolü silinemez' });
    }
    if (!hasPermission(role.server_id, req.user.userId, PERMISSIONS.MANAGE_ROLES)) {
      return res.status(403).json({ error: 'Yetkisiz' });
    }
    db.prepare('DELETE FROM user_roles WHERE role_id = ?').run(roleId);
    db.prepare('DELETE FROM roles WHERE id = ?').run(roleId);
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Bir üyeye rol ata
app.post(
  '/api/servers/:serverId/members/:userId/roles/:roleId',
  authRequired,
  (req, res) => {
    try {
      const serverId = Number(req.params.serverId);
      const targetUserId = Number(req.params.userId);
      const roleId = Number(req.params.roleId);
      if (!hasPermission(serverId, req.user.userId, PERMISSIONS.MANAGE_ROLES)) {
        return res.status(403).json({ error: 'Yetkisiz' });
      }
      const role = db.prepare('SELECT * FROM roles WHERE id = ?').get(roleId);
      if (!role || role.server_id !== serverId) {
        return res.status(404).json({ error: 'Rol bulunamadı' });
      }
      if (role.is_default) {
        return res.status(400).json({ error: '@everyone otomatik atanır' });
      }
      if (!isServerMember(serverId, targetUserId)) {
        return res.status(404).json({ error: 'Üye bulunamadı' });
      }
      db.prepare(
        `INSERT OR IGNORE INTO user_roles (server_id, user_id, role_id, assigned_at)
         VALUES (?, ?, ?, ?)`
      ).run(serverId, targetUserId, roleId, Date.now());
      // Hedef kullanıcıya yeni izinlerini bildir (anlık güncelleme için)
      _notifyPermissionsUpdated(serverId, targetUserId);
      res.json({ ok: true });
    } catch (e) {
      res.status(500).json({ error: e.message });
    }
  }
);

// Üyeden rolü kaldır
app.delete(
  '/api/servers/:serverId/members/:userId/roles/:roleId',
  authRequired,
  (req, res) => {
    try {
      const serverId = Number(req.params.serverId);
      const targetUserId = Number(req.params.userId);
      const roleId = Number(req.params.roleId);
      if (!hasPermission(serverId, req.user.userId, PERMISSIONS.MANAGE_ROLES)) {
        return res.status(403).json({ error: 'Yetkisiz' });
      }
      db.prepare(
        'DELETE FROM user_roles WHERE server_id = ? AND user_id = ? AND role_id = ?'
      ).run(serverId, targetUserId, roleId);
      // Hedef kullanıcıya güncellenmiş izinlerini bildir
      _notifyPermissionsUpdated(serverId, targetUserId);
      res.json({ ok: true });
    } catch (e) {
      res.status(500).json({ error: e.message });
    }
  }
);

// Server üyelerini listele (role + atanmış custom rol id'leri + computed permissions)
app.get('/api/servers/:serverId/members', authRequired, (req, res) => {
  const serverId = Number(req.params.serverId);
  if (!isServerMember(serverId, req.user.userId)) {
    return res.status(403).json({ error: 'Bu sunucunun üyesi değilsin' });
  }
  const members = db
    .prepare(
      `SELECT u.id, u.username, u.email, u.avatar_url, u.virtual_ip, sm.role
       FROM users u
       JOIN server_members sm ON sm.user_id = u.id
       WHERE sm.server_id = ?
       ORDER BY u.username COLLATE NOCASE`
    )
    .all(serverId);
  // Her üye için role ID'leri ve hesaplanan permission'ları ekle
  const out = members.map((m) => {
    const roleIds = db
      .prepare(
        'SELECT role_id FROM user_roles WHERE server_id = ? AND user_id = ?'
      )
      .all(serverId, m.id)
      .map((r) => r.role_id);
    return {
      ...m,
      role_ids: roleIds,
      permissions: computeUserPermissions(serverId, m.id),
    };
  });
  res.json(out);
});

function listChannels(serverId) {
  return db
    .prepare(
      'SELECT id, server_id, name, type FROM channels WHERE server_id = ? ORDER BY type DESC, id'
    )
    .all(serverId);
}

function getChannelServerId(channelId) {
  const row = db
    .prepare('SELECT server_id FROM channels WHERE id = ?')
    .get(channelId);
  return row ? row.server_id : null;
}

function validateChannelName(name) {
  if (typeof name !== 'string') return 'Kanal adı gerekli';
  const trimmed = name.trim();
  if (trimmed.length < 1) return 'Kanal adı boş olamaz';
  if (trimmed.length > 50) return 'Kanal adı en fazla 50 karakter olabilir';
  return null;
}

app.post('/api/servers/:serverId/channels', authRequired, (req, res) => {
  try {
    const serverId = Number(req.params.serverId);
    if (!hasPermission(serverId, req.user.userId, PERMISSIONS.MANAGE_CHANNELS)) {
      return res
        .status(403)
        .json({ error: 'Kanal oluşturma yetkin yok' });
    }
    const { name, type, overrides } = req.body || {};
    const err = validateChannelName(name);
    if (err) return res.status(400).json({ error: err });
    const channelType = type === 'voice' ? 'voice' : 'text';
    const result = db
      .prepare(
        'INSERT INTO channels (server_id, name, type, created_at) VALUES (?, ?, ?, ?)'
      )
      .run(serverId, name.trim(), channelType, Date.now());
    const channelId = result.lastInsertRowid;
    // Olusturma sirasinda bildirilen rol override'larini uygula (opsiyonel).
    // overrides = [{ role_id, allow_perms, deny_perms }, ...]
    if (Array.isArray(overrides)) {
      const upsert = db.prepare(
        `INSERT INTO channel_role_overrides (channel_id, role_id, allow_perms, deny_perms)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(channel_id, role_id) DO UPDATE SET
           allow_perms = excluded.allow_perms,
           deny_perms = excluded.deny_perms`
      );
      for (const o of overrides) {
        const rid = Number(o.role_id);
        if (!rid) continue;
        // Rol bu sunucuya ait mi?
        const role = db.prepare('SELECT id FROM roles WHERE id = ? AND server_id = ?').get(rid, serverId);
        if (!role) continue;
        upsert.run(channelId, rid, (o.allow_perms | 0), (o.deny_perms | 0));
      }
    }
    broadcastChannelsUpdated(serverId);
    res.json({
      id: channelId,
      server_id: serverId,
      name: name.trim(),
      type: channelType,
    });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.patch('/api/channels/:id', authRequired, (req, res) => {
  try {
    const id = Number(req.params.id);
    const channelServerId = getChannelServerId(id);
    if (!channelServerId)
      return res.status(404).json({ error: 'Kanal bulunamadı' });
    if (!hasChannelPermission(id, req.user.userId, PERMISSIONS.MANAGE_CHANNELS)) {
      return res
        .status(403)
        .json({ error: 'Kanal düzenleme yetkin yok' });
    }
    const { name } = req.body || {};
    const err = validateChannelName(name);
    if (err) return res.status(400).json({ error: err });
    db.prepare('UPDATE channels SET name = ? WHERE id = ?').run(
      name.trim(),
      id
    );
    broadcastChannelsUpdated(channelServerId);
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.delete('/api/channels/:id', authRequired, (req, res) => {
  try {
    const id = Number(req.params.id);
    const channelServerId = getChannelServerId(id);
    if (!channelServerId)
      return res.status(404).json({ error: 'Kanal bulunamadı' });
    if (!hasChannelPermission(id, req.user.userId, PERMISSIONS.MANAGE_CHANNELS)) {
      return res
        .status(403)
        .json({ error: 'Kanal silme yetkin yok' });
    }
    db.prepare('DELETE FROM messages WHERE channel_id = ?').run(id);
    db.prepare('DELETE FROM channel_role_overrides WHERE channel_id = ?').run(id);
    db.prepare('DELETE FROM channels WHERE id = ?').run(id);
    for (const info of clients.values()) {
      if (info.voiceChannelId === id) info.voiceChannelId = null;
    }
    broadcastChannelsUpdated(channelServerId);
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

/// Bir kanalin tum rol override'larini doner.
/// Sadece MANAGE_CHANNELS yetkisi olan goruebilir (override'lari).
app.get('/api/channels/:id/permissions', authRequired, (req, res) => {
  try {
    const id = Number(req.params.id);
    const ch = db.prepare('SELECT server_id, type FROM channels WHERE id = ?').get(id);
    if (!ch) return res.status(404).json({ error: 'Kanal bulunamadı' });
    if (!hasChannelPermission(id, req.user.userId, PERMISSIONS.MANAGE_CHANNELS)) {
      return res.status(403).json({ error: 'Kanal yetkilerini goruntuleme yetkin yok' });
    }
    const overrides = db
      .prepare(
        `SELECT role_id, allow_perms, deny_perms
         FROM channel_role_overrides WHERE channel_id = ?`
      )
      .all(id);
    res.json({ channel_id: id, server_id: ch.server_id, type: ch.type, overrides });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

/// Bir rol icin kanal override'ini ayarla (upsert).
/// Body: { allow_perms, deny_perms } — bit'ler.
app.put('/api/channels/:id/permissions/:roleId', authRequired, (req, res) => {
  try {
    const channelId = Number(req.params.id);
    const roleId = Number(req.params.roleId);
    const ch = db.prepare('SELECT server_id FROM channels WHERE id = ?').get(channelId);
    if (!ch) return res.status(404).json({ error: 'Kanal bulunamadı' });
    const role = db.prepare('SELECT id, server_id FROM roles WHERE id = ?').get(roleId);
    if (!role || role.server_id !== ch.server_id) {
      return res.status(400).json({ error: 'Rol bu sunucuya ait degil' });
    }
    if (!hasChannelPermission(channelId, req.user.userId, PERMISSIONS.MANAGE_CHANNELS)) {
      return res.status(403).json({ error: 'Yetki ayarlama yetkin yok' });
    }
    const allow = Math.max(0, (req.body?.allow_perms | 0));
    const deny = Math.max(0, (req.body?.deny_perms | 0));
    db.prepare(
      `INSERT INTO channel_role_overrides (channel_id, role_id, allow_perms, deny_perms)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(channel_id, role_id) DO UPDATE SET
         allow_perms = excluded.allow_perms,
         deny_perms = excluded.deny_perms`
    ).run(channelId, roleId, allow, deny);
    broadcastChannelsUpdated(ch.server_id);
    res.json({ ok: true, channel_id: channelId, role_id: roleId, allow_perms: allow, deny_perms: deny });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

/// Bir rolun kanal override'ini tamamen kaldir (default davranisa don).
app.delete('/api/channels/:id/permissions/:roleId', authRequired, (req, res) => {
  try {
    const channelId = Number(req.params.id);
    const roleId = Number(req.params.roleId);
    const ch = db.prepare('SELECT server_id FROM channels WHERE id = ?').get(channelId);
    if (!ch) return res.status(404).json({ error: 'Kanal bulunamadı' });
    if (!hasChannelPermission(channelId, req.user.userId, PERMISSIONS.MANAGE_CHANNELS)) {
      return res.status(403).json({ error: 'Yetki ayarlama yetkin yok' });
    }
    db.prepare(
      'DELETE FROM channel_role_overrides WHERE channel_id = ? AND role_id = ?'
    ).run(channelId, roleId);
    broadcastChannelsUpdated(ch.server_id);
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Mesaj sil (kendi mesajını herkes; başkasınınkini MANAGE_MESSAGES gerekli)
app.delete('/api/messages/:id', authRequired, (req, res) => {
  try {
    const messageId = Number(req.params.id);
    const message = db
      .prepare(
        'SELECT id, channel_id, user_id FROM messages WHERE id = ?'
      )
      .get(messageId);
    if (!message) return res.status(404).json({ error: 'Mesaj bulunamadı' });
    const channelServerId = getChannelServerId(message.channel_id);
    if (!channelServerId)
      return res.status(404).json({ error: 'Kanal bulunamadı' });

    const isOwn = message.user_id === req.user.userId;
    const canManage = hasPermission(
      channelServerId,
      req.user.userId,
      PERMISSIONS.MANAGE_MESSAGES
    );
    if (!isOwn && !canManage) {
      return res
        .status(403)
        .json({ error: 'Bu mesajı silme yetkin yok' });
    }

    db.prepare('DELETE FROM messages WHERE id = ?').run(messageId);

    // Sunucu üyelerine broadcast
    const payload = JSON.stringify({
      type: 'message-deleted',
      messageId,
      channelId: message.channel_id,
      serverId: channelServerId,
    });
    for (const ws of clients.keys()) {
      const info = clients.get(ws);
      if (
        info &&
        ws.readyState === ws.OPEN &&
        isServerMember(channelServerId, info.userId)
      ) {
        ws.send(payload);
      }
    }
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.get('/api/channels/:id/messages', authRequired, (req, res) => {
  const channelId = Number(req.params.id);
  const serverId = getChannelServerId(channelId);
  if (!serverId)
    return res.status(404).json({ error: 'Kanal bulunamadı' });
  if (!isServerMember(serverId, req.user.userId)) {
    return res.status(403).json({ error: 'Yetkisiz' });
  }
  const messages = db.prepare(`
    SELECT m.id, m.channel_id, m.user_id, m.username, m.content, m.created_at,
           u.avatar_url
    FROM messages m
    LEFT JOIN users u ON u.id = m.user_id
    WHERE m.channel_id = ?
    ORDER BY m.id DESC
    LIMIT 50
  `).all(channelId).reverse();
  res.json(messages);
});

const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: '/ws' });

// ws -> { userId, username, voiceChannelId|null, screenSharing, cameraSharing }
const clients = new Map();

function findWsByUserId(userId) {
  for (const [ws, info] of clients) {
    if (info.userId === userId) return ws;
  }
  return null;
}

/// Kullanıcının rol değişikliği sonrası güncellenmiş permissions'ını WS ile gönder.
function _notifyPermissionsUpdated(serverId, userId) {
  try {
    const ws = findWsByUserId(userId);
    if (ws && ws.readyState === ws.OPEN) {
      const newPerms = computeUserPermissions(serverId, userId);
      ws.send(JSON.stringify({
        type: 'permissions-updated',
        serverId,
        permissions: newPerms,
      }));
    }
  } catch (_) {}
}

function getVoiceMembers(channelId) {
  const members = [];
  for (const info of clients.values()) {
    if (info.voiceChannelId === channelId) {
      const user = getUserById(info.userId);
      members.push({
        userId: info.userId,
        username: info.username,
        screenSharing: !!info.screenSharing,
        cameraSharing: !!info.cameraSharing,
        avatar_url: user ? user.avatar_url : null,
      });
    }
  }
  return members;
}

function broadcastVoiceMembers(channelId) {
  const members = getVoiceMembers(channelId);
  const serverId = getChannelServerId(channelId);
  const payload = JSON.stringify({
    type: 'voice-members',
    channelId,
    serverId,
    members,
  });
  for (const ws of clients.keys()) {
    const info = clients.get(ws);
    if (!info) continue;
    // Sadece o sunucunun üyelerine yolla
    if (
      ws.readyState === ws.OPEN &&
      (!serverId || isServerMember(serverId, info.userId))
    ) {
      ws.send(payload);
    }
  }
}

function broadcastChannelsUpdated(serverId) {
  const allChannels = listChannels(serverId);
  // Her kullaniciya kendi gorebilecegi kanallari yolla (view perm filtresi).
  // MANAGE_CHANNELS yetkisi olanlar tum kanallari gorur.
  for (const ws of clients.keys()) {
    const info = clients.get(ws);
    if (!info) continue;
    if (ws.readyState !== ws.OPEN || !isServerMember(serverId, info.userId)) continue;
    const canManageAll = hasPermission(serverId, info.userId, PERMISSIONS.MANAGE_CHANNELS);
    const visible = canManageAll
      ? allChannels
      : allChannels.filter((c) =>
          hasChannelPermission(c.id, info.userId, PERMISSIONS.VIEW_CHANNELS)
        );
    ws.send(JSON.stringify({
      type: 'channels-updated',
      serverId,
      channels: visible,
    }));
  }
}

function getOnlineUserIds() {
  const ids = new Set();
  for (const info of clients.values()) {
    ids.add(info.userId);
  }
  return Array.from(ids);
}

function broadcastPresence() {
  const payload = JSON.stringify({
    type: 'presence-updated',
    onlineUserIds: getOnlineUserIds(),
  });
  for (const ws of clients.keys()) {
    if (ws.readyState === ws.OPEN) ws.send(payload);
  }
}

function broadcastUserListUpdated() {
  const users = db
    .prepare(
      'SELECT id, username, email, avatar_url, virtual_ip FROM users ORDER BY username COLLATE NOCASE'
    )
    .all();
  const payload = JSON.stringify({ type: 'users-updated', users });
  for (const ws of clients.keys()) {
    if (ws.readyState === ws.OPEN) ws.send(payload);
  }
}

/// Bir kullanıcının profili (username/email/avatar) değişince çağrılır.
/// Bağlı oturumlardaki cached username'i günceller ve tüm istemcilere
/// "user-profile-updated" yayını yapar — eski mesajlardaki avatar/username
/// canlı güncellensin diye.
function broadcastUserProfileUpdated(user) {
  // WS oturumlarındaki username'i güncelle
  for (const info of clients.values()) {
    if (info.userId === user.id) {
      info.username = user.username;
    }
  }
  // Sesli kanallarda kullanıcı görünüyorsa üye listesini güncellet
  const channelIdsToRefresh = new Set();
  for (const info of clients.values()) {
    if (info.userId === user.id && info.voiceChannelId !== null) {
      channelIdsToRefresh.add(info.voiceChannelId);
    }
  }
  for (const channelId of channelIdsToRefresh) {
    broadcastVoiceMembers(channelId);
  }

  // Tüm istemcilere profil güncellemesini bildir
  const payload = JSON.stringify({
    type: 'user-profile-updated',
    user: {
      userId: user.id,
      username: user.username,
      avatar_url: user.avatar_url,
    },
  });
  for (const ws of clients.keys()) {
    if (ws.readyState === ws.OPEN) ws.send(payload);
  }
}

wss.on('connection', (ws, req) => {
  const url = new URL(req.url, 'http://localhost');
  const token = url.searchParams.get('token');
  const payload = verifyToken(token);

  if (!payload) {
    ws.close(1008, 'Geçersiz token');
    return;
  }

  clients.set(ws, {
    userId: payload.userId,
    username: payload.username,
    voiceChannelId: null,
    screenSharing: false,
    cameraSharing: false,
  });
  console.log(`[WS] ${payload.username} bağlandı (toplam: ${clients.size})`);

  ws.send(JSON.stringify({ type: 'hello', username: payload.username, userId: payload.userId }));
  // Yeni bağlanan'a anlık presence durumunu gönder
  ws.send(JSON.stringify({
    type: 'presence-updated',
    onlineUserIds: getOnlineUserIds(),
  }));
  // Diğerlerine yeni online'ı bildir
  broadcastPresence();

  ws.on('message', (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      return;
    }

    const client = clients.get(ws);
    if (!client) return;

    // --- Ping (RTT ölçümü için) ---
    if (msg.type === 'ping') {
      ws.send(JSON.stringify({ type: 'pong', ts: msg.ts }));
      return;
    }

    // --- Text mesajı ---
    if (msg.type === 'message' && msg.channelId && msg.content) {
      const channelServerId = getChannelServerId(msg.channelId);
      if (!channelServerId ||
          !hasChannelPermission(msg.channelId, client.userId, PERMISSIONS.SEND_MESSAGES) ||
          !hasChannelPermission(msg.channelId, client.userId, PERMISSIONS.VIEW_CHANNELS)) {
        return; // Mesaj gönderme yetkisi yok
      }
      const content = String(msg.content).slice(0, 2000);
      const createdAt = Date.now();

      const result = db.prepare(
        'INSERT INTO messages (channel_id, user_id, username, content, created_at) VALUES (?, ?, ?, ?, ?)'
      ).run(msg.channelId, client.userId, client.username, content, createdAt);

      const senderUser = getUserById(client.userId);
      const broadcast = JSON.stringify({
        type: 'message',
        id: result.lastInsertRowid,
        channelId: msg.channelId,
        serverId: channelServerId,
        userId: client.userId,
        username: client.username,
        content,
        createdAt,
        avatar_url: senderUser ? senderUser.avatar_url : null,
      });

      // Sadece o sunucunun üyelerine yolla
      for (const peer of clients.keys()) {
        const peerInfo = clients.get(peer);
        if (
          peerInfo &&
          peer.readyState === peer.OPEN &&
          isServerMember(channelServerId, peerInfo.userId)
        ) {
          peer.send(broadcast);
        }
      }
      return;
    }

    // --- Sesli kanala katıl ---
    if (msg.type === 'voice-join' && typeof msg.channelId === 'number') {
      const channelServerId = getChannelServerId(msg.channelId);
      if (!channelServerId ||
          !hasChannelPermission(msg.channelId, client.userId, PERMISSIONS.CONNECT_VOICE) ||
          !hasChannelPermission(msg.channelId, client.userId, PERMISSIONS.VIEW_CHANNELS)) {
        return; // Sesli kanal bağlantı yetkisi yok
      }
      // Önce başka bir voice kanaldaysa oradan çık
      if (client.voiceChannelId !== null) {
        const oldId = client.voiceChannelId;
        client.voiceChannelId = null;
        broadcastVoiceMembers(oldId);
      }

      client.voiceChannelId = msg.channelId;

      // Yeni katılan kişiye kanaldaki diğer üyeleri gönder
      // (yeni katılan, mevcut olanlara WebRTC offer gönderecek)
      const existingMembers = getVoiceMembers(msg.channelId).filter(
        (m) => m.userId !== client.userId
      );
      ws.send(JSON.stringify({
        type: 'voice-joined',
        channelId: msg.channelId,
        existingMembers,
      }));

      broadcastVoiceMembers(msg.channelId);
      console.log(`[VOICE] ${client.username} kanala katıldı: ${msg.channelId}`);
      return;
    }

    // --- Sesli kanaldan ayrıl ---
    if (msg.type === 'voice-leave') {
      if (client.voiceChannelId !== null) {
        const oldId = client.voiceChannelId;
        client.voiceChannelId = null;
        broadcastVoiceMembers(oldId);
        console.log(`[VOICE] ${client.username} kanaldan ayrıldı: ${oldId}`);
      }
      return;
    }

    // --- Ekran paylaşımı durumu güncelle ---
    if (msg.type === 'voice-screen-state' && typeof msg.sharing === 'boolean') {
      client.screenSharing = msg.sharing;
      if (client.voiceChannelId !== null) {
        broadcastVoiceMembers(client.voiceChannelId);
      }
      console.log(`[VOICE] ${client.username} ekran paylaşımı: ${msg.sharing}`);
      return;
    }

    // --- Kamera paylaşımı durumu güncelle ---
    if (msg.type === 'voice-camera-state' && typeof msg.sharing === 'boolean') {
      client.cameraSharing = msg.sharing;
      if (client.voiceChannelId !== null) {
        broadcastVoiceMembers(client.voiceChannelId);
      }
      console.log(`[VOICE] ${client.username} kamera paylaşımı: ${msg.sharing}`);
      return;
    }

    // --- WebRTC signaling (SDP veya ICE candidate) yönlendir ---
    if (msg.type === 'voice-signal' && typeof msg.toUserId === 'number' && msg.payload) {
      const target = findWsByUserId(msg.toUserId);
      if (target && target.readyState === target.OPEN) {
        target.send(JSON.stringify({
          type: 'voice-signal',
          fromUserId: client.userId,
          fromUsername: client.username,
          payload: msg.payload,
        }));
      }
      return;
    }
  });

  ws.on('close', () => {
    const client = clients.get(ws);
    const wasInVoice = client && client.voiceChannelId !== null;
    const oldVoiceId = wasInVoice ? client.voiceChannelId : null;
    clients.delete(ws);
    if (oldVoiceId !== null) {
      broadcastVoiceMembers(oldVoiceId);
    }
    if (client) {
      console.log(`[WS] ${client.username} ayrıldı (toplam: ${clients.size})`);
      // Aynı userId'nin başka WS oturumu yoksa offline olur
      const stillOnline = Array.from(clients.values()).some(
        (c) => c.userId === client.userId
      );
      if (!stillOnline) broadcastPresence();
    }
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, '0.0.0.0', () => {
  console.log(`Sunucu çalışıyor: http://localhost:${PORT}`);
  console.log(`WebSocket:        ws://localhost:${PORT}/ws`);
});
