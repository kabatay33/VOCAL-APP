# LocalHub uygulama ikonu üretici.
# Modern, minimal bir "hub" konsepti: ortada bir node (yuvarlak),
# etrafinda 4 bagli kucuk node — yerel ag konseptini cagristirir.
# Discord renk paletinden ilham: koyu lacivert arka plan + parlak mavi vurgular.
from PIL import Image, ImageDraw, ImageFilter
import math, os

OUT_PNG = os.path.join(os.path.dirname(__file__), '..', 'assets_src', 'app_icon.png')
OUT_ICO = os.path.join(os.path.dirname(__file__), '..', 'flutter_app', 'windows', 'runner', 'resources', 'app_icon.ico')
OUT_ICO_ASSETS = os.path.join(os.path.dirname(__file__), '..', 'flutter_app', 'assets', 'app_icon.ico')

# Yuksek cozunurlukte ciz, sonra kucult — anti-alias daha iyi cikar
SIZE = 1024
SCALE = 4
W = SIZE
H = SIZE

# Renk paleti
BG_DARK = (32, 34, 37, 255)        # #202225 - Discord dark
BG_GRADIENT = (47, 49, 54, 255)    # #2F3136
ACCENT = (88, 101, 242, 255)       # #5865F2 - Discord blurple
ACCENT_LIGHT = (114, 137, 218, 255)  # eski Discord blurple
GLOW = (88, 101, 242, 80)
WHITE = (255, 255, 255, 255)
GREEN = (87, 242, 135, 255)        # online dot rengi

def rounded_rect(draw, xy, radius, fill):
    x0, y0, x1, y1 = xy
    draw.rounded_rectangle(xy, radius=radius, fill=fill)

def make_icon(size):
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    pad = int(size * 0.02)
    # Arka plan: yuvarlak kose kare, koyu arkaplan
    bg_rect = (pad, pad, size - pad, size - pad)
    radius = int(size * 0.22)
    d.rounded_rectangle(bg_rect, radius=radius, fill=BG_DARK)

    # Hafif radyal ust gradient — manuel iki katmanli circle
    overlay = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    cx, cy = size // 2, int(size * 0.42)
    rr = int(size * 0.55)
    od.ellipse((cx - rr, cy - rr, cx + rr, cy + rr), fill=(88, 101, 242, 40))
    overlay = overlay.filter(ImageFilter.GaussianBlur(radius=size * 0.08))
    img.alpha_composite(overlay)
    d = ImageDraw.Draw(img)

    # Hub ag: ortada buyuk node, etrafinda 4 kucuk node, baglanti cizgileri
    center = (size // 2, size // 2)
    big_r = int(size * 0.12)
    small_r = int(size * 0.07)
    ring_r = int(size * 0.32)

    # 4 satelite konumu (kuzey/dogu/guney/bati - 45 derece kaymis)
    sats = []
    for i in range(4):
        ang = math.pi / 4 + i * math.pi / 2
        sx = center[0] + int(math.cos(ang) * ring_r)
        sy = center[1] + int(math.sin(ang) * ring_r)
        sats.append((sx, sy))

    # Baglanti cizgileri (ince, parlak mavi)
    line_w = max(2, int(size * 0.012))
    for sx, sy in sats:
        d.line([center, (sx, sy)], fill=ACCENT, width=line_w)

    # Kucuk node'lar (disardakiler)
    for sx, sy in sats:
        # Disc halka — ic kismi yarisaydam
        d.ellipse((sx - small_r, sy - small_r, sx + small_r, sy + small_r),
                  fill=ACCENT_LIGHT)
        # Ic parlak nokta
        ir = small_r // 2
        d.ellipse((sx - ir, sy - ir, sx + ir, sy + ir), fill=WHITE)

    # Buyuk merkez node — parlak Discord blurple
    d.ellipse((center[0] - big_r, center[1] - big_r,
               center[0] + big_r, center[1] + big_r),
              fill=ACCENT)
    # Ic beyaz "L" sembolu cizmek yerine basit ic dolgu
    ir2 = int(big_r * 0.55)
    d.ellipse((center[0] - ir2, center[1] - ir2,
               center[0] + ir2, center[1] + ir2),
              fill=WHITE)
    # Ortada kucuk yesil online nokta — "yerel/aktif" hissi
    gr = int(size * 0.025)
    d.ellipse((center[0] - gr, center[1] - gr,
               center[0] + gr, center[1] + gr),
              fill=GREEN)

    return img

# Ana yuksek cozunurlukte ciz
master = make_icon(SIZE)

# assets_src yedek
os.makedirs(os.path.dirname(OUT_PNG), exist_ok=True)
master.save(OUT_PNG, 'PNG')
print(f"PNG kaydedildi: {OUT_PNG}")

# ICO: Windows icin coklu cozunurluk
ico_sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
ico_images = [master.resize(s, Image.LANCZOS) for s in ico_sizes]

# Birinci ICO konumu
os.makedirs(os.path.dirname(OUT_ICO), exist_ok=True)
ico_images[0].save(OUT_ICO, format='ICO', sizes=ico_sizes,
                   append_images=ico_images[1:])
print(f"ICO kaydedildi: {OUT_ICO}")

# Asset kopyasi
os.makedirs(os.path.dirname(OUT_ICO_ASSETS), exist_ok=True)
ico_images[0].save(OUT_ICO_ASSETS, format='ICO', sizes=ico_sizes,
                   append_images=ico_images[1:])
print(f"ICO kopyasi kaydedildi: {OUT_ICO_ASSETS}")
print("OK")
