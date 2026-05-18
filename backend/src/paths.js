// LocalHub kullanici verisi dizinleri.
//
// Windows: Program Files'a kurulan installer admin yetkisi gerektirir,
// dolayisiyla DB ve uploads gibi yazilabilir dosyalar buraya yazilamaz.
// Bunlari %LOCALAPPDATA%\LocalHub\ icine koyariz (kullanici yazilabilir).
//
// Geliştirme (npm start): proje root\ icinde kalsin (eski davranis).
// Production (installer): %LOCALAPPDATA%\LocalHub\ kullanilir.

const path = require('path');
const fs = require('fs');
const os = require('os');

/// User data dizini: yazilabilir, kullaniciya ozel.
/// Windows: %LOCALAPPDATA%\LocalHub
/// Diger:   ~/.localhub
function getUserDataDir() {
  // Geliştirme modunda backend root'unda kal (dev iterations icin pratik)
  // backend/src/paths.js -> backend/ -> proje root degil.
  // Dev'i tespit: LOCALHUB_DEV env veya backend klasoru "Program Files"
  // disindaysa dev say.
  const backendDir = path.resolve(__dirname, '..');
  const isInProgramFiles = backendDir.toLowerCase().includes('\\program files');
  const isProduction = isInProgramFiles || process.env.LOCALHUB_PROD === '1';

  if (!isProduction) {
    // Dev: backend klasorune yaz (legacy davranis)
    return backendDir;
  }

  // Production
  let baseDir;
  if (process.platform === 'win32') {
    baseDir = process.env.LOCALAPPDATA ||
      path.join(os.homedir(), 'AppData', 'Local');
  } else if (process.platform === 'darwin') {
    baseDir = path.join(os.homedir(), 'Library', 'Application Support');
  } else {
    baseDir = process.env.XDG_DATA_HOME ||
      path.join(os.homedir(), '.local', 'share');
  }
  const dir = path.join(baseDir, 'LocalHub');
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  return dir;
}

const userDataDir = getUserDataDir();

const paths = {
  userDataDir,
  dbFile: path.join(userDataDir, 'data.db'),
  uploadsDir: path.join(userDataDir, 'uploads'),
};

// Uploads klasorunu olustur
if (!fs.existsSync(paths.uploadsDir)) {
  fs.mkdirSync(paths.uploadsDir, { recursive: true });
}

console.log(`[PATHS] userDataDir = ${userDataDir}`);
console.log(`[PATHS] dbFile      = ${paths.dbFile}`);
console.log(`[PATHS] uploadsDir  = ${paths.uploadsDir}`);

module.exports = paths;
