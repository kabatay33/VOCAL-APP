const Database = require('better-sqlite3');
const path = require('path');

const db = new Database(path.join(__dirname, '..', 'data.db'));
db.pragma('journal_mode = WAL');

db.exec(`
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    email TEXT,
    avatar_url TEXT,
    password_hash TEXT NOT NULL,
    created_at INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS servers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    owner_user_id INTEGER NOT NULL,
    invite_code TEXT UNIQUE NOT NULL,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (owner_user_id) REFERENCES users(id)
  );

  CREATE TABLE IF NOT EXISTS server_members (
    server_id INTEGER NOT NULL,
    user_id INTEGER NOT NULL,
    role TEXT NOT NULL DEFAULT 'member',
    joined_at INTEGER NOT NULL,
    PRIMARY KEY (server_id, user_id),
    FOREIGN KEY (server_id) REFERENCES servers(id),
    FOREIGN KEY (user_id) REFERENCES users(id)
  );

  CREATE TABLE IF NOT EXISTS roles (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id INTEGER NOT NULL,
    name TEXT NOT NULL,
    color TEXT DEFAULT '#99AAB5',
    permissions INTEGER NOT NULL DEFAULT 0,
    position INTEGER NOT NULL DEFAULT 0,
    is_default INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (server_id) REFERENCES servers(id)
  );

  CREATE TABLE IF NOT EXISTS user_roles (
    server_id INTEGER NOT NULL,
    user_id INTEGER NOT NULL,
    role_id INTEGER NOT NULL,
    assigned_at INTEGER NOT NULL,
    PRIMARY KEY (server_id, user_id, role_id),
    FOREIGN KEY (role_id) REFERENCES roles(id),
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (server_id) REFERENCES servers(id)
  );

  CREATE TABLE IF NOT EXISTS channels (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id INTEGER NOT NULL DEFAULT 1,
    name TEXT NOT NULL,
    type TEXT NOT NULL DEFAULT 'text',
    created_at INTEGER NOT NULL,
    FOREIGN KEY (server_id) REFERENCES servers(id)
  );

  CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id INTEGER NOT NULL,
    user_id INTEGER NOT NULL,
    username TEXT NOT NULL,
    content TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (channel_id) REFERENCES channels(id),
    FOREIGN KEY (user_id) REFERENCES users(id)
  );
`);

// Eski veritabanı için 'type' sütununu güvenli şekilde ekle
try {
  const cols = db.prepare("PRAGMA table_info(channels)").all();
  if (!cols.some(c => c.name === 'type')) {
    db.exec("ALTER TABLE channels ADD COLUMN type TEXT NOT NULL DEFAULT 'text'");
  }
  if (!cols.some(c => c.name === 'server_id')) {
    db.exec("ALTER TABLE channels ADD COLUMN server_id INTEGER NOT NULL DEFAULT 1");
  }
} catch (_) { /* ignore */ }

// Eski channels tablosunda name UNIQUE constraint vardı, kaldır
try {
  const def = db
    .prepare(
      "SELECT sql FROM sqlite_master WHERE type='table' AND name='channels'"
    )
    .get();
  if (def && /name\s+TEXT\s+UNIQUE/i.test(def.sql)) {
    console.log(
      '[MIGRATION] channels.name UNIQUE constraint kaldırılıyor (per-server isimler)'
    );
    // FK kontrolünü geçici kapat (channels_new oluşturulurken messages.channel_id FK ihlali olmasın)
    db.exec('PRAGMA foreign_keys = OFF');
    db.exec(`
      BEGIN TRANSACTION;
      CREATE TABLE channels_new (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        server_id INTEGER NOT NULL DEFAULT 1,
        name TEXT NOT NULL,
        type TEXT NOT NULL DEFAULT 'text',
        created_at INTEGER NOT NULL
      );
      INSERT INTO channels_new (id, server_id, name, type, created_at)
        SELECT id, COALESCE(server_id, 1), name, type, created_at FROM channels;
      DROP TABLE channels;
      ALTER TABLE channels_new RENAME TO channels;
      COMMIT;
    `);
    db.exec('PRAGMA foreign_keys = ON');
    console.log('[MIGRATION] channels recreate başarılı');
  }
} catch (e) {
  console.error('[MIGRATION] channels recreate:', e.message);
  try {
    db.exec('ROLLBACK');
  } catch (_) {}
  try {
    db.exec('PRAGMA foreign_keys = ON');
  } catch (_) {}
}

// Eski users tablosuna eksik kolonları ekle
try {
  const cols = db.prepare("PRAGMA table_info(users)").all();
  if (!cols.some(c => c.name === 'email')) {
    db.exec("ALTER TABLE users ADD COLUMN email TEXT");
    db.exec(
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email ON users(email) WHERE email IS NOT NULL"
    );
  }
  if (!cols.some(c => c.name === 'avatar_url')) {
    db.exec("ALTER TABLE users ADD COLUMN avatar_url TEXT");
  }
  if (!cols.some(c => c.name === 'virtual_ip')) {
    db.exec("ALTER TABLE users ADD COLUMN virtual_ip TEXT");
    db.exec(
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_virtual_ip ON users(virtual_ip) WHERE virtual_ip IS NOT NULL"
    );
  }
} catch (_) { /* ignore */ }

/// Hamachi/Radmin tarzı sanal IP üretici.
/// Format: 26.X.Y.Z — Radmin VPN ile aynı kozmetik aralık.
/// Bir int (userId/random) → deterministic ama tekil bir IP'ye dönüşür.
function generateVirtualIp(seed) {
  // 26.0.0.1 - 26.255.255.254 arası (≈16M adres)
  const x = (seed >>> 16) & 0xff;
  const y = (seed >>> 8) & 0xff;
  const z = seed & 0xff;
  // 0 ve 255 sakat olabilir; basit kayma
  const safeX = (x === 0 || x === 255) ? 1 : x;
  const safeZ = (z === 0 || z === 255) ? 1 : z;
  return `26.${safeX}.${y}.${safeZ}`;
}

/// Tüm kullanıcılara virtual_ip ata (çakışma olursa sonraki seed'i dene).
try {
  const missing = db
    .prepare('SELECT id FROM users WHERE virtual_ip IS NULL')
    .all();
  if (missing.length > 0) {
    const exists = db.prepare(
      'SELECT 1 FROM users WHERE virtual_ip = ?'
    );
    const update = db.prepare(
      'UPDATE users SET virtual_ip = ? WHERE id = ?'
    );
    for (const u of missing) {
      let attempt = 0;
      let ip;
      do {
        // userId tabanlı seed + collision olursa karıştır
        ip = generateVirtualIp(u.id + attempt * 7919);
        attempt++;
      } while (exists.get(ip) && attempt < 100);
      update.run(ip, u.id);
    }
    console.log(`[MIGRATION] ${missing.length} kullanıcıya virtual_ip atandı`);
  }
} catch (e) {
  console.error('[MIGRATION] virtual_ip atama hatası:', e.message);
}

// (generateVirtualIp dışarıya export'a aşağıda eklenir)

// Default sunucu oluştur (id=1) — mevcut tüm kanallar buraya bağlanır
function generateInviteCode() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  let code = '';
  for (let i = 0; i < 8; i++) {
    code += chars[Math.floor(Math.random() * chars.length)];
  }
  return code;
}

const {
  DEFAULT_EVERYONE_PERMS,
  DEFAULT_ADMIN_PERMS,
} = require('./permissions');

try {
  const existingServers = db.prepare('SELECT id FROM servers').all();
  if (existingServers.length === 0) {
    // İlk sunucu oluştur. owner_user_id = ilk kullanıcı (varsa) veya 1
    const firstUser = db.prepare('SELECT id FROM users ORDER BY id LIMIT 1').get();
    const ownerId = firstUser ? firstUser.id : 1;
    const now = Date.now();
    db.prepare(
      'INSERT INTO servers (id, name, owner_user_id, invite_code, created_at) VALUES (1, ?, ?, ?, ?)'
    ).run('Varsayılan Sunucu', ownerId, generateInviteCode(), now);
    console.log('[MIGRATION] Default sunucu oluşturuldu (id=1)');
  }

  // Tüm mevcut kullanıcıları default server'a üye yap (yoksa)
  const users = db.prepare('SELECT id FROM users').all();
  const insertMember = db.prepare(
    `INSERT OR IGNORE INTO server_members (server_id, user_id, role, joined_at)
     VALUES (1, ?, ?, ?)`
  );
  const defaultOwner = db.prepare('SELECT owner_user_id FROM servers WHERE id = 1').get();
  for (const user of users) {
    const role = (defaultOwner && defaultOwner.owner_user_id === user.id) ? 'owner' : 'member';
    insertMember.run(user.id, role, Date.now());
  }
} catch (e) {
  console.error('[MIGRATION] servers/members hatası:', e.message);
}

// Her sunucu için varsayılan @everyone ve Admin rolleri (yoksa)
try {
  const allServers = db.prepare('SELECT id FROM servers').all();
  const insertRole = db.prepare(
    `INSERT INTO roles (server_id, name, color, permissions, position, is_default, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)`
  );
  const findRole = db.prepare(
    'SELECT id FROM roles WHERE server_id = ? AND name = ?'
  );
  const now = Date.now();

  for (const srv of allServers) {
    let everyoneId, adminId;
    const everyone = findRole.get(srv.id, '@everyone');
    if (!everyone) {
      const r = insertRole.run(
        srv.id,
        '@everyone',
        '#99AAB5',
        DEFAULT_EVERYONE_PERMS,
        0,
        1, // is_default = true
        now
      );
      everyoneId = r.lastInsertRowid;
    } else {
      everyoneId = everyone.id;
    }

    const admin = findRole.get(srv.id, 'Admin');
    if (!admin) {
      const r = insertRole.run(
        srv.id,
        'Admin',
        '#ED4245',
        DEFAULT_ADMIN_PERMS,
        100,
        0,
        now
      );
      adminId = r.lastInsertRowid;
    } else {
      adminId = admin.id;
    }

    // Eski server_members.role = 'admin' olanlara Admin rolü ata
    const oldAdmins = db
      .prepare(
        `SELECT user_id FROM server_members
         WHERE server_id = ? AND role = 'admin'`
      )
      .all(srv.id);
    const assignRole = db.prepare(
      `INSERT OR IGNORE INTO user_roles (server_id, user_id, role_id, assigned_at)
       VALUES (?, ?, ?, ?)`
    );
    for (const u of oldAdmins) {
      assignRole.run(srv.id, u.user_id, adminId, now);
    }
  }
  console.log('[MIGRATION] roles & default rol atamaları tamamlandı');
} catch (e) {
  console.error('[MIGRATION] roles hatası:', e.message);
}

// channels.name artık unique değil (her sunucuda aynı isim olabilir).
// Default sunucu için varsayılan kanalları oluştur (yoksa)
const defaultChannels = [
  { name: 'genel', type: 'text' },
  { name: 'sohbet', type: 'text' },
  { name: 'oyun', type: 'text' },
  { name: 'Sesli Oda 1', type: 'voice' },
  { name: 'Sesli Oda 2', type: 'voice' },
];
try {
  const hasDefault = db
    .prepare('SELECT id FROM channels WHERE server_id = 1 LIMIT 1')
    .get();
  if (!hasDefault) {
    const insertChannel = db.prepare(
      'INSERT INTO channels (server_id, name, type, created_at) VALUES (1, ?, ?, ?)'
    );
    for (const c of defaultChannels) {
      insertChannel.run(c.name, c.type, Date.now());
    }
  }
} catch (_) {}

module.exports = db;
module.exports.generateVirtualIp = generateVirtualIp;
