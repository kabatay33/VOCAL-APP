// Bildirim sesi WAV dosyalarını üretir (16-bit PCM mono, 44.1 kHz).
// Discord benzeri kısa, hafif tonlar.
const fs = require('fs');
const path = require('path');

const SAMPLE_RATE = 44100;
const BITS_PER_SAMPLE = 16;
const NUM_CHANNELS = 1;

function writeWav(filename, samples) {
  const dataSize = samples.length * 2;
  const buffer = Buffer.alloc(44 + dataSize);
  // RIFF header
  buffer.write('RIFF', 0);
  buffer.writeUInt32LE(36 + dataSize, 4);
  buffer.write('WAVE', 8);
  // fmt chunk
  buffer.write('fmt ', 12);
  buffer.writeUInt32LE(16, 16); // PCM chunk size
  buffer.writeUInt16LE(1, 20); // PCM format
  buffer.writeUInt16LE(NUM_CHANNELS, 22);
  buffer.writeUInt32LE(SAMPLE_RATE, 24);
  buffer.writeUInt32LE(SAMPLE_RATE * NUM_CHANNELS * BITS_PER_SAMPLE / 8, 28);
  buffer.writeUInt16LE(NUM_CHANNELS * BITS_PER_SAMPLE / 8, 32);
  buffer.writeUInt16LE(BITS_PER_SAMPLE, 34);
  // data chunk
  buffer.write('data', 36);
  buffer.writeUInt32LE(dataSize, 40);
  for (let i = 0; i < samples.length; i++) {
    const s = Math.max(-1, Math.min(1, samples[i]));
    buffer.writeInt16LE(Math.round(s * 32767), 44 + i * 2);
  }
  fs.writeFileSync(filename, buffer);
  console.log(`Yazıldı: ${filename} (${samples.length} sample, ${(samples.length / SAMPLE_RATE * 1000).toFixed(0)}ms)`);
}

/// Bir sinüs tonu üretir. Attack/release ile soft envelope.
function tone({ freq, durationMs, volume = 0.5, attackMs = 5, releaseMs = 30 }) {
  const total = Math.round((durationMs / 1000) * SAMPLE_RATE);
  const attack = Math.round((attackMs / 1000) * SAMPLE_RATE);
  const release = Math.round((releaseMs / 1000) * SAMPLE_RATE);
  const samples = new Float32Array(total);
  for (let i = 0; i < total; i++) {
    let env = 1;
    if (i < attack) env = i / attack;
    else if (i > total - release) env = (total - i) / release;
    samples[i] = Math.sin(2 * Math.PI * freq * i / SAMPLE_RATE) * volume * env;
  }
  return samples;
}

/// İki dizi sample'ı birleştirir.
function concat(...arrs) {
  const total = arrs.reduce((s, a) => s + a.length, 0);
  const out = new Float32Array(total);
  let off = 0;
  for (const a of arrs) {
    out.set(a, off);
    off += a.length;
  }
  return out;
}

/// Sample'ları toplar (mix). Aynı uzunluk varsayılır.
function mix(...arrs) {
  const total = arrs[0].length;
  const out = new Float32Array(total);
  for (let i = 0; i < total; i++) {
    let v = 0;
    for (const a of arrs) v += a[i] || 0;
    out[i] = v;
  }
  return out;
}

const outDir = path.join(__dirname, '..', 'assets', 'sounds');
fs.mkdirSync(outDir, { recursive: true });

// 1) message.wav — kısa "ding" (yüksek tek nota + ufak harmonik)
{
  const base = tone({ freq: 880, durationMs: 100, volume: 0.35 });
  const high = tone({ freq: 1320, durationMs: 100, volume: 0.18 });
  const samples = mix(base, high);
  writeWav(path.join(outDir, 'message.wav'), samples);
}

// 2) user_joined.wav — yükselen iki ton (Discord stili, hafif)
{
  const t1 = tone({ freq: 523, durationMs: 90, volume: 0.4, releaseMs: 25 });
  const t2 = tone({ freq: 784, durationMs: 130, volume: 0.4, attackMs: 8, releaseMs: 40 });
  const samples = concat(t1, t2);
  writeWav(path.join(outDir, 'user_joined.wav'), samples);
}

// 3) user_left.wav — alçalan iki ton
{
  const t1 = tone({ freq: 784, durationMs: 90, volume: 0.4, releaseMs: 25 });
  const t2 = tone({ freq: 523, durationMs: 130, volume: 0.4, attackMs: 8, releaseMs: 40 });
  const samples = concat(t1, t2);
  writeWav(path.join(outDir, 'user_left.wav'), samples);
}

// 4) self_joined.wav — daha sıcak/dolgun bir "bağlandın" sesi (üç ton akoru)
{
  const len = Math.round(0.25 * SAMPLE_RATE);
  const t1 = tone({ freq: 392, durationMs: 250, volume: 0.25, attackMs: 8, releaseMs: 60 });
  const t2 = tone({ freq: 523, durationMs: 250, volume: 0.25, attackMs: 8, releaseMs: 60 });
  const t3 = tone({ freq: 659, durationMs: 250, volume: 0.22, attackMs: 12, releaseMs: 70 });
  const samples = mix(t1, t2, t3);
  writeWav(path.join(outDir, 'self_joined.wav'), samples);
}

// 5) self_left.wav — düşen tek ton
{
  const samples = tone({ freq: 392, durationMs: 200, volume: 0.4, attackMs: 8, releaseMs: 100 });
  writeWav(path.join(outDir, 'self_left.wav'), samples);
}

// 6) share_started.wav — "yayın başladı" ascending arpej (C5-E5-G5 sıralı)
{
  const t1 = tone({ freq: 523, durationMs: 70, volume: 0.32, attackMs: 4, releaseMs: 20 });
  const t2 = tone({ freq: 659, durationMs: 70, volume: 0.32, attackMs: 4, releaseMs: 20 });
  const t3 = tone({ freq: 784, durationMs: 140, volume: 0.32, attackMs: 4, releaseMs: 50 });
  const samples = concat(t1, t2, t3);
  writeWav(path.join(outDir, 'share_started.wav'), samples);
}

// 7) share_stopped.wav — "yayın bitti" descending arpej
{
  const t1 = tone({ freq: 784, durationMs: 70, volume: 0.3, attackMs: 4, releaseMs: 20 });
  const t2 = tone({ freq: 659, durationMs: 70, volume: 0.3, attackMs: 4, releaseMs: 20 });
  const t3 = tone({ freq: 523, durationMs: 140, volume: 0.3, attackMs: 4, releaseMs: 50 });
  const samples = concat(t1, t2, t3);
  writeWav(path.join(outDir, 'share_stopped.wav'), samples);
}

console.log('Tüm sesler üretildi.');
