#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Thyra — viewer.py"""

import os, sys, time, signal, logging, subprocess, requests, tempfile
from pathlib import Path

BASE_DIR   = Path(os.environ.get("THYRA_HOME", "/opt/thyra"))
ASSETS_DIR = BASE_DIR / "assets"
FLAG_FILE  = BASE_DIR / "reload.flag"
API_BASE   = "http://127.0.0.1:5000"
POLL_INTERVAL   = 30
RETRY_INTERVAL  = 5
SPLASH_DELAY    = 30  # secondes avant d'afficher le splash si playlist vide

logging.basicConfig(level=logging.INFO,
    format="%(asctime)s [viewer] %(levelname)s %(message)s")
log = logging.getLogger("thyra.viewer")

_current_proc = None
_should_exit  = False

def _which(names):
    import shutil
    for n in names:
        p = shutil.which(n)
        if p: return p
    return None

IMAGE_VIEWER = _which(["feh", "fbi", "display"])
VIDEO_PLAYER = _which(["cvlc", "vlc"])
CHROMIUM_BIN = _which(["chromium", "chromium-browser", "google-chrome"])
log.info("Binaires — images:%s  vidéo:%s  web:%s",
         IMAGE_VIEWER, VIDEO_PLAYER, CHROMIUM_BIN)

def kill_current():
    global _current_proc
    if _current_proc and _current_proc.poll() is None:
        try:
            _current_proc.terminate()
            _current_proc.wait(timeout=3)
        except Exception:
            try: _current_proc.kill()
            except Exception: pass
    _current_proc = None

def signal_handler(sig, frame):
    global _should_exit
    log.info("Signal %s — arrêt", sig)
    _should_exit = True
    kill_current()
    sys.exit(0)

def _display_env():
    env = os.environ.copy()
    env.setdefault("DISPLAY", ":0")
    env.setdefault("XAUTHORITY",
        f"/home/{os.environ.get('THYRA_USER','thyra')}/.Xauthority")
    return env

def fetch_api(path, default):
    try:
        r = requests.get(f"{API_BASE}{path}", timeout=5)
        if r.ok: return r.json()
    except Exception as e:
        log.warning("API %s : %s", path, e)
    return default

def wait_for_server(max_wait=90):
    log.info("Attente serveur…")
    for _ in range(max_wait // 3):
        try:
            requests.get(f"{API_BASE}/api/settings", timeout=2)
            log.info("Serveur prêt")
            return True
        except Exception:
            time.sleep(3)
    return False

def local_path_for_uri(uri):
    if uri.startswith("/assets_files/"):
        parts = uri.split("/")
        if len(parts) >= 4:
            return ASSETS_DIR / parts[2] / parts[3]
    return None

def reload_requested():
    if FLAG_FILE.exists():
        try:    direction = FLAG_FILE.read_text().strip() or "reload"
        except: direction = "reload"
        FLAG_FILE.unlink(missing_ok=True)
        return True, direction
    return False, None

def apply_rotation(settings):
    rot_map = {"0":"normal","1":"right","2":"inverted","3":"left"}
    xr  = rot_map.get(str(settings.get("display_rotate","0")), "normal")
    env = _display_env()
    for output in ("HDMI-1","HDMI-2","HDMI-A-1","HDMI-A-2"):
        r = subprocess.run(["xrandr","--output",output,"--rotate",xr],
            env=env, capture_output=True, timeout=5)
        if r.returncode == 0:
            log.info("Rotation %s sur %s", xr, output)
            return
    subprocess.run(["xrandr","--auto"], env=env, timeout=5, capture_output=True)

def set_black_background():
    env = _display_env()
    try:
        subprocess.run(["xsetroot","-solid","black"],
            env=env, timeout=3, capture_output=True)
    except Exception: pass

def show_splash():
    splash = BASE_DIR / "static" / "img" / "splash.png"
    if not splash.exists():
        splash = BASE_DIR / "static" / "img" / "splash.svg"
    if not splash.exists() or not IMAGE_VIEWER: return
    env = _display_env()
    try:
        if "feh" in IMAGE_VIEWER:
            cmd = ["feh","--fullscreen","--hide-pointer","--scale-down",
                   "--auto-zoom","--no-menus","--borderless",
                   "--image-bg","black", str(splash)]
        else:
            cmd = ["fbi","-T","1","-d","/dev/fb0","--noverbose",
                   "--fitwidth","-a", str(splash)]
        p = subprocess.Popen(cmd, env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        p.wait(timeout=5)
    except Exception as e:
        log.warning("Splash échoué : %s", e)

def resolve_path(asset):
    uri   = asset["uri"]
    local = local_path_for_uri(uri)
    if local and local.exists(): return str(local)
    return uri if uri.startswith("http") else API_BASE + uri

# ── Slideshow feh — zéro coupure entre images ─────────────────────────────
def play_image_sequence(assets):
    global _current_proc
    import urllib.request

    paths     = []
    durations = []
    for a in assets:
        p = resolve_path(a)
        if p.startswith("http"):
            try:
                suffix = Path(p.split("?")[0]).suffix or ".jpg"
                tmp = tempfile.NamedTemporaryFile(delete=False, suffix=suffix)
                urllib.request.urlretrieve(p, tmp.name)
                paths.append(tmp.name)
            except Exception as e:
                log.warning("Téléchargement échoué : %s", e)
                continue
        else:
            paths.append(p)
        durations.append(int(a.get("duration", 10)))

    if not paths: return False
    if not IMAGE_VIEWER or "feh" not in IMAGE_VIEWER: return False

    duration = durations[0] if durations else 10
    env      = _display_env()

    log.info("Slideshow feh — %d images × %ds", len(paths), duration)
    cmd = ["feh","--fullscreen","--hide-pointer","--scale-down",
           "--auto-zoom","--no-menus","--borderless","--image-bg","black",
           "--slideshow-delay", str(duration),
           "--cycle-once"] + paths
    try:
        _current_proc = subprocess.Popen(cmd, env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        total   = duration * len(paths)
        elapsed = 0
        while elapsed < total + 2 and _current_proc.poll() is None:
            has_reload, direction = reload_requested()
            if has_reload:
                FLAG_FILE.write_text(direction)
                kill_current()
                return False
            time.sleep(0.5)
            elapsed += 0.5
        kill_current()
        return True
    except Exception as e:
        log.error("feh slideshow : %s", e)
        kill_current()
        return False

# ── Lecteurs individuels ──────────────────────────────────────────────────
def play_image(asset, duration):
    global _current_proc
    path = resolve_path(asset)
    if path.startswith("http"):
        try:
            suffix = Path(path.split("?")[0]).suffix or ".jpg"
            tmp = tempfile.NamedTemporaryFile(delete=False, suffix=suffix)
            import urllib.request
            urllib.request.urlretrieve(path, tmp.name)
            path = tmp.name
        except Exception as e:
            log.error("Téléchargement image : %s", e)
            time.sleep(duration); return

    env = _display_env()
    if not IMAGE_VIEWER: time.sleep(duration); return

    if "feh" in IMAGE_VIEWER:
        cmd = ["feh","--fullscreen","--hide-pointer","--scale-down",
               "--auto-zoom","--no-menus","--borderless",
               "--image-bg","black", path]
    elif "fbi" in IMAGE_VIEWER:
        cmd = ["fbi","-T","1","-d","/dev/fb0","--noverbose","--fitwidth","-a",path]
    else:
        cmd = [IMAGE_VIEWER, path]

    log.info("IMAGE %s — %ds", asset["name"], duration)
    try:
        _current_proc = subprocess.Popen(cmd, env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        _current_proc.wait(timeout=duration + 2)
    except subprocess.TimeoutExpired: kill_current()
    except FileNotFoundError:
        log.error("Viewer image introuvable"); time.sleep(duration)

def play_video(asset, duration, single_asset=False):
    global _current_proc
    target  = resolve_path(asset)
    env     = _display_env()
    vlc_bin = VIDEO_PLAYER

    if not vlc_bin:
        log.error("VLC introuvable"); time.sleep(max(duration,5)); return

    if single_asset:
        loop_args = ["--loop"]
    else:
        loop_args = ["--no-loop","--play-and-exit"]

    cmd = [vlc_bin,"--no-osd"] + loop_args + [
          "--no-video-title-show","--fullscreen",
          "--vout=gl","--aout=alsa","--no-qt-error-dialogs",
          "--aspect-ratio=16:9","--zoom=2", target]

    log.info("VIDEO %s [vlc loop=%s] — %ds",
             asset["name"], single_asset, duration)
    try:
        _current_proc = subprocess.Popen(cmd, env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if single_asset:
            # Boucle infinie — surveille le reload
            while _current_proc.poll() is None:
                has_reload, direction = reload_requested()
                if has_reload:
                    FLAG_FILE.write_text(direction)
                    kill_current()
                    return
                time.sleep(1)
        else:
            _current_proc.wait(timeout=duration + 5 if duration > 0 else None)
    except subprocess.TimeoutExpired: kill_current()
    except FileNotFoundError:
        log.error("VLC introuvable"); time.sleep(max(duration,5))

def play_webpage(asset, duration):
    global _current_proc
    uri = asset["uri"]
    if not uri.startswith("http"): uri = API_BASE + uri
    if not CHROMIUM_BIN:
        log.error("Chromium introuvable"); time.sleep(duration); return

    env = _display_env()
    cmd = [CHROMIUM_BIN,"--kiosk","--noerrdialogs","--disable-infobars",
           "--disable-session-crashed-bubble","--disable-restore-session-state",
           "--no-first-run","--disable-component-update",
           "--check-for-update-interval=31536000",
           "--autoplay-policy=no-user-gesture-required", uri]

    log.info("WEB %s — %ds", asset["name"], duration)
    try:
        _current_proc = subprocess.Popen(cmd, env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        _current_proc.wait(timeout=duration + 2)
    except subprocess.TimeoutExpired: kill_current()
    except FileNotFoundError:
        log.error("Chromium introuvable"); time.sleep(duration)

# ── Boucle principale ─────────────────────────────────────────────────────
def main():
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT,  signal_handler)

    log.info("Thyra viewer démarré — HOME=%s", BASE_DIR)
    wait_for_server()

    settings = fetch_api("/api/settings", {})
    apply_rotation(settings)
    set_black_background()

    # Splash uniquement au démarrage initial
    if settings.get("show_splash", "1") == "1":
        show_splash()
        set_black_background()

    playlist    = []
    playlist_ts = 0
    idx         = 0
    empty_since = None

    while not _should_exit:
        now = time.time()

        has_reload, direction = reload_requested()
        if has_reload:
            new_settings = fetch_api("/api/settings", settings)
            if new_settings.get("display_rotate") != settings.get("display_rotate"):
                apply_rotation(new_settings)
            settings = new_settings
            playlist = fetch_api("/api/playlist", [])
            playlist_ts = now
            if direction == "prev":   idx = max(0, idx - 2)
            elif direction != "next": idx = 0
            kill_current()

        elif now - playlist_ts > POLL_INTERVAL or not playlist:
            new_pl = fetch_api("/api/playlist", [])
            if new_pl != playlist:
                log.info("Playlist mise à jour : %d asset(s)", len(new_pl))
                playlist = new_pl
                idx = 0
            playlist_ts = now

        if not playlist:
            if empty_since is None:
                empty_since = now
                set_black_background()
                log.info("Playlist vide — fond noir")
            elif (now - empty_since > SPLASH_DELAY
                  and settings.get("show_splash","1") == "1"):
                log.info("Playlist vide depuis %ds — splash", SPLASH_DELAY)
                show_splash()
            time.sleep(RETRY_INTERVAL)
            continue

        # Playlist non vide
        empty_since = None

        if idx >= len(playlist):
            idx = 0

        # Slideshow feh si 100% images
        if IMAGE_VIEWER and "feh" in IMAGE_VIEWER:
            all_images = all(a.get("asset_type") == "image" for a in playlist)
            if all_images:
                log.info("Playlist 100%% images — slideshow feh")
                play_image_sequence(playlist)
                idx = 0
                continue

        # Lecture individuelle
        asset    = playlist[idx]
        atype    = asset.get("asset_type","")
        duration = int(asset.get("duration", 10))

        log.info("[%d/%d] %s (%s) — %ds",
                 idx+1, len(playlist), asset["name"], atype, duration)

        kill_current()

        if   atype == "image":
            play_image(asset, duration)
        elif atype == "video":
            play_video(asset, duration, single_asset=len(playlist)==1)
        elif atype == "webpage":
            play_webpage(asset, duration)
        else:
            log.warning("Type inconnu : %s", atype)
            time.sleep(5)

        kill_current()
        idx += 1

if __name__ == "__main__":
    main()
