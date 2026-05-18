const bcrypt = require('bcrypt');
const jwt = require('jsonwebtoken');
const db = require('./db');
const { generateVirtualIp } = require('./db');

/// Kullanıcı için benzersiz bir virtual_ip üret (çakışma varsa seed'i değiştir)
function assignVirtualIp(userId) {
  const exists = db.prepare('SELECT 1 FROM users WHERE virtual_ip = ?');
  let attempt = 0;
  let ip;
  do {
    ip = generateVirtualIp(userId + attempt * 7919);
    attempt++;
  } while (exists.get(ip) && attempt < 100);
  return ip;
}

const JWT_SECRET = process.env.JWT_SECRET || 'degistir-bu-gizli-anahtari-uretimde';
const TOKEN_EXPIRY = '7d';

const EMAIL_REGEX = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function validateEmail(email) {
  if (typeof email !== 'string' || !EMAIL_REGEX.test(email.trim())) {
    throw new Error('Geçersiz e-posta adresi');
  }
  return email.trim().toLowerCase();
}

function validateUsername(username) {
  if (typeof username !== 'string') {
    throw new Error('Kullanıcı adı gerekli');
  }
  const u = username.trim();
  if (u.length < 3) throw new Error('Kullanıcı adı en az 3 karakter olmalı');
  if (u.length > 32) throw new Error('Kullanıcı adı en fazla 32 karakter olabilir');
  return u;
}

function validatePassword(password) {
  if (typeof password !== 'string' || password.length < 6) {
    throw new Error('Şifre en az 6 karakter olmalı');
  }
}

async function register(email, username, password) {
  const cleanEmail = validateEmail(email);
  const cleanUsername = validateUsername(username);
  validatePassword(password);

  const emailExists = db.prepare('SELECT id FROM users WHERE email = ?').get(cleanEmail);
  if (emailExists) throw new Error('Bu e-posta zaten kayıtlı');

  const usernameExists = db.prepare('SELECT id FROM users WHERE username = ?').get(cleanUsername);
  if (usernameExists) throw new Error('Bu kullanıcı adı zaten alınmış');

  const passwordHash = await bcrypt.hash(password, 10);
  const result = db.prepare(
    'INSERT INTO users (username, email, password_hash, created_at) VALUES (?, ?, ?, ?)'
  ).run(cleanUsername, cleanEmail, passwordHash, Date.now());

  const userId = result.lastInsertRowid;
  // Sanal IP ata
  const virtualIp = assignVirtualIp(userId);
  db.prepare('UPDATE users SET virtual_ip = ? WHERE id = ?').run(virtualIp, userId);

  const token = jwt.sign({ userId, username: cleanUsername }, JWT_SECRET, { expiresIn: TOKEN_EXPIRY });
  return {
    token,
    user: {
      id: userId,
      username: cleanUsername,
      email: cleanEmail,
      avatar_url: null,
      virtual_ip: virtualIp,
    },
  };
}

async function login(email, password) {
  const cleanEmail = validateEmail(email);
  const user = db.prepare(
    'SELECT id, username, email, avatar_url, virtual_ip, password_hash FROM users WHERE email = ?'
  ).get(cleanEmail);
  if (!user) throw new Error('E-posta veya şifre hatalı');

  const ok = await bcrypt.compare(password, user.password_hash);
  if (!ok) throw new Error('E-posta veya şifre hatalı');

  // Eski hesap virtual_ip'siz olabilir — şimdi ata
  let virtualIp = user.virtual_ip;
  if (!virtualIp) {
    virtualIp = assignVirtualIp(user.id);
    db.prepare('UPDATE users SET virtual_ip = ? WHERE id = ?').run(virtualIp, user.id);
  }

  const token = jwt.sign({ userId: user.id, username: user.username }, JWT_SECRET, { expiresIn: TOKEN_EXPIRY });
  return {
    token,
    user: {
      id: user.id,
      username: user.username,
      email: user.email,
      avatar_url: user.avatar_url,
      virtual_ip: virtualIp,
    },
  };
}

/// Sadece username ile giriş. Kullanıcı yoksa otomatik oluşturulur.
/// Şifre/email gerekmez. Aynı username ile farklı cihazdan giriş yapan
/// son kişinin tokeni aktif olur (eski tokenler hala valid kalır — JWT stateless).
async function loginByUsername(username) {
  const cleanUsername = validateUsername(username);
  let user = db.prepare(
    'SELECT id, username, email, avatar_url, virtual_ip FROM users WHERE username = ?'
  ).get(cleanUsername);

  if (!user) {
    // Yeni kullanıcı oluştur — şifresiz hesap.
    // password_hash NOT NULL kolonu olduğu için boş string yazıyoruz (eski DB
    // schema uyumu). Username-only mode'da bcrypt.compare hiç çağrılmıyor.
    const result = db.prepare(
      'INSERT INTO users (username, email, password_hash, created_at) VALUES (?, NULL, ?, ?)'
    ).run(cleanUsername, '', Date.now());
    const userId = result.lastInsertRowid;
    const virtualIp = assignVirtualIp(userId);
    db.prepare('UPDATE users SET virtual_ip = ? WHERE id = ?').run(virtualIp, userId);
    user = {
      id: userId,
      username: cleanUsername,
      email: null,
      avatar_url: null,
      virtual_ip: virtualIp,
    };
  } else if (!user.virtual_ip) {
    // Eski hesap virtual_ip'siz olabilir — şimdi ata
    const virtualIp = assignVirtualIp(user.id);
    db.prepare('UPDATE users SET virtual_ip = ? WHERE id = ?').run(virtualIp, user.id);
    user.virtual_ip = virtualIp;
  }

  const token = jwt.sign(
    { userId: user.id, username: user.username },
    JWT_SECRET,
    { expiresIn: TOKEN_EXPIRY }
  );
  return {
    token,
    user: {
      id: user.id,
      username: user.username,
      email: user.email,
      avatar_url: user.avatar_url,
      virtual_ip: user.virtual_ip,
    },
  };
}

function verifyToken(token) {
  try {
    return jwt.verify(token, JWT_SECRET);
  } catch {
    return null;
  }
}

function getUserById(id) {
  return db
    .prepare('SELECT id, username, email, avatar_url, virtual_ip FROM users WHERE id = ?')
    .get(id);
}

function setUserAvatar(id, avatarUrl) {
  db.prepare('UPDATE users SET avatar_url = ? WHERE id = ?').run(avatarUrl, id);
  return getUserById(id);
}

function getUserByIdInternal(id) {
  return db
    .prepare('SELECT id, username, email, avatar_url, virtual_ip FROM users WHERE id = ?')
    .get(id);
}

async function updateProfile(userId, { username, email, password, currentPassword }) {
  const user = db.prepare(
    'SELECT id, username, email, avatar_url, password_hash FROM users WHERE id = ?'
  ).get(userId);
  if (!user) throw new Error('Kullanıcı bulunamadı');

  const updates = {};

  if (username !== undefined && username !== null) {
    const cleanUsername = validateUsername(username);
    if (cleanUsername !== user.username) {
      const exists = db.prepare(
        'SELECT id FROM users WHERE username = ? AND id != ?'
      ).get(cleanUsername, userId);
      if (exists) throw new Error('Bu kullanıcı adı zaten alınmış');
      updates.username = cleanUsername;
    }
  }

  if (email !== undefined && email !== null) {
    const cleanEmail = validateEmail(email);
    if (cleanEmail !== user.email) {
      const exists = db.prepare(
        'SELECT id FROM users WHERE email = ? AND id != ?'
      ).get(cleanEmail, userId);
      if (exists) throw new Error('Bu e-posta zaten kullanılıyor');
      updates.email = cleanEmail;
    }
  }

  if (password !== undefined && password !== null && password.length > 0) {
    // Şifre değişikliği için mevcut şifre doğrulaması
    if (!currentPassword) throw new Error('Mevcut şifrenizi girmelisiniz');
    const ok = await bcrypt.compare(currentPassword, user.password_hash);
    if (!ok) throw new Error('Mevcut şifre hatalı');
    validatePassword(password);
    updates.password_hash = await bcrypt.hash(password, 10);
  }

  if (Object.keys(updates).length === 0) {
    return { id: user.id, username: user.username, email: user.email };
  }

  const setParts = Object.keys(updates).map((k) => `${k} = ?`).join(', ');
  const values = Object.values(updates);
  db.prepare(`UPDATE users SET ${setParts} WHERE id = ?`).run(...values, userId);

  const updated = getUserById(userId);
  return updated;
}

module.exports = {
  register,
  login,
  loginByUsername,
  verifyToken,
  getUserById,
  updateProfile,
  setUserAvatar,
};
