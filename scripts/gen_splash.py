#!/usr/bin/env python3
"""Thyra — gen_splash.py
Génère le splash screen 1920x1080 avec l'IP courante et le QR code WiFi.
Appelé au boot et après connexion WiFi.
"""

from PIL import Image, ImageDraw, ImageFont
import qrcode, socket, sqlite3, os
from pathlib import Path

BASE = Path(os.environ.get("THYRA_HOME", "/opt/thyra"))


def get_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "192.168.73.1"


def get_setting(key, default=""):
    try:
        db = sqlite3.connect(str(BASE / "db" / "thyra.db"))
        row = db.execute(
            "SELECT value FROM settings WHERE key=?", (key,)
        ).fetchone()
        db.close()
        return row[0] if row else default
    except Exception:
        return default


def gen():
    ip          = get_ip()
    url         = f"http://{ip}/"
    player_name = get_setting("player_name", "Thyra Player")

    img  = Image.new("RGB", (1920, 1080), "#0f0f13")
    draw = ImageDraw.Draw(img)

    try:
        font_big   = ImageFont.truetype(
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 120)
        font_med   = ImageFont.truetype(
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 48)
        font_small = ImageFont.truetype(
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 36)
    except Exception:
        font_big = font_med = font_small = ImageFont.load_default()

    draw.text((960, 260), "Thyra",       font=font_big,   fill="#6366f1", anchor="mm")
    draw.text((960, 390), player_name,   font=font_med,   fill="#818cf8", anchor="mm")
    draw.text((960, 455), "θύρα · Digital Signage",
              font=font_small, fill="#4b4b6a", anchor="mm")
    draw.text((960, 555), "Interface d'administration :",
              font=font_small, fill="#6b6b8a", anchor="mm")
    draw.text((960, 610), url,           font=font_med,   fill="#e4e4f0", anchor="mm")

    # QR code
    qr = qrcode.QRCode(box_size=8, border=2)
    qr.add_data(url)
    qr.make(fit=True)
    qr_img = qr.make_image(
        fill_color="#6366f1", back_color="#0f0f13"
    ).convert("RGB")
    qr_x = (1920 - qr_img.size[0]) // 2
    img.paste(qr_img, (qr_x, 670))
    draw.text((960, 680 + qr_img.size[1]),
              "Scannez pour accéder à l'interface",
              font=font_small, fill="#6b6b8a", anchor="mm")

    out = BASE / "static" / "img" / "splash.png"
    img.save(str(out))
    print(f"Splash OK — {url} — {out}")


if __name__ == "__main__":
    gen()
