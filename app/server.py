#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Thyra — server.py — Backend Flask + API REST"""

import os, uuid, hashlib, sqlite3, logging, mimetypes, subprocess, platform
from datetime import datetime
from functools import wraps
from pathlib import Path

from flask import (
    Flask, request, jsonify, render_template,
    redirect, url_for, session, send_from_directory, abort, flash
)
from werkzeug.utils import secure_filename
from werkzeug.security import generate_password_hash, check_password_hash

BASE_DIR   = Path(os.environ.get("THYRA_HOME", "/opt/thyra"))
ASSETS_DIR = BASE_DIR / "assets"
DB_PATH    = BASE_DIR / "db" / "thyra.db"
SECRET_KEY = os.environ.get("THYRA_SECRET", "thyra-change-me-in-production")
MAX_MB     = int(os.environ.get("THYRA_MAX_MB", 1024))

ALLOWED_IMAGE = {"jpg","jpeg","png","gif","bmp","webp","svg"}
ALLOWED_VIDEO = {"mp4","webm","mkv","avi","mov","m4v","flv","ts"}
ALLOWED_WEB   = {"html","htm"}
ALLOWED_EXT   = ALLOWED_IMAGE | ALLOWED_VIDEO | ALLOWED_WEB

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("thyra.server")

app = Flask(
    __name__,
    template_folder=str(BASE_DIR / "templates"),
    static_folder=str(BASE_DIR / "static"),
)
app.secret_key = SECRET_KEY
app.config["MAX_CONTENT_LENGTH"] = MAX_MB * 1024 * 1024

ASSETS_DIR.mkdir(parents=True, exist_ok=True)
(BASE_DIR / "db").mkdir(parents=True, exist_ok=True)

# ── Database ──────────────────────────────────────────────────────────────────
def get_db():
    db = sqlite3.connect(str(DB_PATH), detect_types=sqlite3.PARSE_DECLTYPES)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=DELETE")
    db.execute("PRAGMA foreign_keys=ON")
    return db

def init_db():
    db = get_db()
    db.executescript("""
        CREATE TABLE IF NOT EXISTS users (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT    UNIQUE NOT NULL,
            password TEXT    NOT NULL,
            role     TEXT    NOT NULL DEFAULT 'viewer'
        );
        CREATE TABLE IF NOT EXISTS assets (
            asset_id    TEXT    PRIMARY KEY,
            name        TEXT    NOT NULL,
            uri         TEXT    NOT NULL,
            mimetype    TEXT    NOT NULL DEFAULT '',
            asset_type  TEXT    NOT NULL,
            duration    INTEGER NOT NULL DEFAULT 10,
            play_for    TEXT    NOT NULL DEFAULT 'manual',
            is_active   INTEGER NOT NULL DEFAULT 1,
            skip_check  INTEGER NOT NULL DEFAULT 0,
            md5         TEXT    NOT NULL DEFAULT '',
            start_date  TEXT,
            end_date    TEXT,
            created_at  TEXT    NOT NULL,
            updated_at  TEXT    NOT NULL
        );
        CREATE TABLE IF NOT EXISTS schedule (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            asset_id    TEXT    NOT NULL REFERENCES assets(asset_id) ON DELETE CASCADE,
            name        TEXT    NOT NULL DEFAULT '',
            start_date  TEXT,
            end_date    TEXT,
            start_time  TEXT    DEFAULT '00:00',
            end_time    TEXT    DEFAULT '23:59',
            days        TEXT    DEFAULT '1111111',
            priority    INTEGER NOT NULL DEFAULT 0,
            is_enabled  INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE IF NOT EXISTS settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL DEFAULT ''
        );
    """)
    if not db.execute("SELECT id FROM users WHERE username='admin'").fetchone():
        db.execute(
            "INSERT INTO users (username, password, role) VALUES (?,?,?)",
            ("admin", generate_password_hash("admin"), "admin")
        )
        log.warning("Compte admin créé — mot de passe par défaut 'admin', changez-le !")
    defaults = {
        "player_name":"Thyra Player","timezone":"Europe/Paris",
        "date_format":"year-month-day","use_24h_clock":"1",
        "default_duration":"10","default_streaming_duration":"300",
        "shuffle_playlist":"0","show_splash":"1","default_assets":"0",
        "display_rotate":"0","overscan":"0","audio_output":"hdmi",
        "auth_backend":"basic","debug_logging":"0",
        "ap_enabled":"0","ap_ssid":"Thyra","ap_password":"thyrasignage","ap_channel":"6",
        "hostname":"thyra","first_run":"1",
    }
    for k, v in defaults.items():
        db.execute("INSERT OR IGNORE INTO settings (key, value) VALUES (?,?)", (k, v))
    db.commit()
    db.close()
    log.info("DB initialisée — %s", DB_PATH)

def get_setting(key, default=""):
    db = get_db()
    row = db.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
    db.close()
    return row["value"] if row else default

def set_setting(key, value):
    db = get_db()
    db.execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?,?)", (key, str(value)))
    db.commit()
    db.close()

def get_all_settings():
    db = get_db()
    rows = db.execute("SELECT key, value FROM settings").fetchall()
    db.close()
    return {r["key"]: r["value"] for r in rows}

# ── Auth ──────────────────────────────────────────────────────────────────────
def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if get_setting("auth_backend", "basic") == "disabled":
            if not session.get("user_id"):
                session.update({"user_id":1,"username":"admin","role":"admin"})
            return f(*args, **kwargs)
        if not session.get("user_id"):
            return redirect(url_for("login", next=request.path))
        return f(*args, **kwargs)
    return decorated

def admin_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get("user_id"):
            return redirect(url_for("login"))
        if session.get("role") != "admin":
            abort(403)
        return f(*args, **kwargs)
    return decorated

# ── Helpers ───────────────────────────────────────────────────────────────────
def allowed_file(filename):
    return "." in filename and filename.rsplit(".",1)[1].lower() in ALLOWED_EXT

def detect_type(filename):
    ext = filename.rsplit(".",1)[-1].lower()
    if ext in ALLOWED_IMAGE: return "image"
    if ext in ALLOWED_VIDEO: return "video"
    if ext in ALLOWED_WEB:   return "webpage"
    return "unknown"

def md5_file(path):
    h = hashlib.md5()
    with open(path,"rb") as f:
        for chunk in iter(lambda: f.read(65536), b""): h.update(chunk)
    return h.hexdigest()

def now_iso():
    return datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S")

def asset_plays_now(asset, schedules):
    if not asset["is_active"]:
        return False
    play_for = asset["play_for"] or "manual"
    now = datetime.now()
    if play_for == "manual":
        if asset["start_date"]:
            try:
                if now < datetime.fromisoformat(asset["start_date"]): return False
            except ValueError: pass
        if asset["end_date"]:
            try:
                if now > datetime.fromisoformat(asset["end_date"]): return False
            except ValueError: pass
        return True
    if not schedules: return False
    dow = now.weekday()
    time_str = now.strftime("%H:%M")
    for s in schedules:
        if not s["is_enabled"]: continue
        days = s["days"] or "1111111"
        if len(days) < 7 or days[dow] != "1": continue
        if s["start_date"]:
            try:
                if now.date() < datetime.fromisoformat(s["start_date"]).date(): continue
            except ValueError: pass
        if s["end_date"]:
            try:
                if now.date() > datetime.fromisoformat(s["end_date"]).date(): continue
            except ValueError: pass
        if time_str < (s["start_time"] or "00:00"): continue
        if time_str > (s["end_time"]   or "23:59"): continue
        return True
    return False

# ── Auth routes ───────────────────────────────────────────────────────────────
@app.route("/login", methods=["GET","POST"])
def login():
    if get_setting("auth_backend","basic") == "disabled":
        session.update({"user_id":1,"username":"admin","role":"admin"})
        return redirect(url_for("schedule_overview"))
    if request.method == "POST":
        username = request.form.get("username","").strip()
        password = request.form.get("password","")
        db = get_db()
        user = db.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
        db.close()
        if user and check_password_hash(user["password"], password):
            session.update({"user_id":user["id"],"username":user["username"],"role":user["role"]})
            return redirect(request.form.get("next") or url_for("schedule_overview"))
        flash("Identifiants incorrects.", "error")
    return render_template("login.html")

@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))

# ── UI routes ─────────────────────────────────────────────────────────────────
@app.route("/")
@login_required
def index():
    return redirect(url_for("schedule_overview"))

@app.route("/schedule")
@login_required
def schedule_overview():
    db = get_db()
    active   = db.execute("SELECT * FROM assets WHERE is_active=1 ORDER BY created_at DESC").fetchall()
    inactive = db.execute("SELECT * FROM assets WHERE is_active=0 ORDER BY created_at DESC").fetchall()
    db.close()
    return render_template("schedule.html", active_assets=active, inactive_assets=inactive)

@app.route("/settings", methods=["GET"])
@admin_required
def settings_view():
    s = get_all_settings()
    db = get_db()
    users = db.execute("SELECT id, username, role FROM users ORDER BY id").fetchall()
    db.close()
    qr_exists = (BASE_DIR / "static" / "img" / "wifi_qr.png").exists()
    return render_template("settings.html", s=s, users=users, qr_exists=qr_exists)

@app.route("/settings", methods=["POST"])
@admin_required
def settings_save():
    keys = [
        "player_name","timezone","date_format","use_24h_clock",
        "default_duration","default_streaming_duration","shuffle_playlist",
        "show_splash","default_assets","display_rotate","overscan",
        "audio_output","auth_backend","debug_logging",
        "ap_enabled","ap_ssid","ap_password","ap_channel",
    ]
    db = get_db()
    for k in keys:
        val = request.form.get(k, "0")
        db.execute("INSERT OR REPLACE INTO settings (key,value) VALUES (?,?)", (k, val))
    db.commit()
    db.close()
    (BASE_DIR / "reload.flag").write_text("reload")
    flash("Paramètres enregistrés.", "success")
    return redirect(url_for("settings_view"))

@app.route("/system_info")
@admin_required
def system_info_view():
    return render_template("system_info.html", info=_get_system_info())

def _get_system_info():
    info = {}
    try:
        info["hostname"]  = subprocess.check_output(["hostname"], text=True).strip()
        info["uptime"]    = subprocess.check_output(["uptime","-p"], text=True).strip()
        info["kernel"]    = subprocess.check_output(["uname","-r"], text=True).strip()
        info["os"]        = platform.platform()
        info["arch"]      = platform.machine()
        info["cpu_count"] = os.cpu_count()
        info["python"]    = platform.python_version()

        with open("/proc/meminfo") as f:
            meminfo = dict(line.split(":",1) for line in f if ":" in line)
        total_kb = int(meminfo.get("MemTotal","0 kB").strip().split()[0])
        avail_kb = int(meminfo.get("MemAvailable","0 kB").strip().split()[0])
        info["mem_total_mb"] = total_kb // 1024
        info["mem_free_mb"]  = avail_kb // 1024
        info["mem_used_mb"]  = info["mem_total_mb"] - info["mem_free_mb"]

        stat = os.statvfs(str(BASE_DIR))
        info["disk_total_gb"] = round(stat.f_frsize * stat.f_blocks / 1e9, 1)
        info["disk_free_gb"]  = round(stat.f_frsize * stat.f_bavail / 1e9, 1)
        info["disk_used_gb"]  = round(info["disk_total_gb"] - info["disk_free_gb"], 1)

        temp_path = Path("/sys/class/thermal/thermal_zone0/temp")
        info["cpu_temp"] = f"{int(temp_path.read_text().strip()) / 1000:.1f}°C" \
                           if temp_path.exists() else "N/A"

        info["ip_addresses"] = subprocess.check_output(
            ["hostname","-I"], text=True).strip().split()

        db = get_db()
        info["asset_count"]  = db.execute("SELECT COUNT(*) FROM assets").fetchone()[0]
        info["active_count"] = db.execute("SELECT COUNT(*) FROM assets WHERE is_active=1").fetchone()[0]
        db.close()

        # Supervisor via XML-RPC sur socket Unix — pas de dépendance sudo
        try:
            import xmlrpc.client, http.client, socket as _socket
            class _T(xmlrpc.client.Transport):
                def make_connection(self, host):
                    c = http.client.HTTPConnection("localhost")
                    c.sock = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
                    c.sock.connect("/var/run/supervisor.sock")
                    return c
            srv   = xmlrpc.client.ServerProxy("http://localhost", transport=_T())
            procs = srv.supervisor.getAllProcessInfo()
            info["supervisor"] = [
                f"{p['name']:<25} {p['statename']:<10} pid={p['pid']}"
                for p in procs
            ]
        except Exception as e:
            log.warning("supervisor xmlrpc inaccessible : %s", e)
            info["supervisor"] = []

        ver_file = BASE_DIR / "VERSION"
        info["version"] = ver_file.read_text().strip() if ver_file.exists() else "dev"

    except Exception as e:
        log.warning("system_info error: %s", e)
        info["error"] = str(e)
    return info

# ── API Assets ────────────────────────────────────────────────────────────────
@app.route("/api/assets", methods=["GET"])
@login_required
def api_assets():
    db = get_db()
    rows = db.execute("SELECT * FROM assets ORDER BY created_at DESC").fetchall()
    db.close()
    return jsonify([dict(r) for r in rows])

@app.route("/api/assets", methods=["POST"])
@login_required
def api_asset_add():
    asset_type = request.form.get("asset_type","")
    name       = request.form.get("name","").strip()
    duration   = int(request.form.get("duration", get_setting("default_duration","10")))
    is_active  = int(request.form.get("is_active", 1))
    play_for   = request.form.get("play_for","manual")
    start_date = request.form.get("start_date") or None
    end_date   = request.form.get("end_date")   or None
    aid  = str(uuid.uuid4())
    now  = now_iso()
    mime = ""
    md5  = ""

    if asset_type == "webpage":
        uri = request.form.get("uri","").strip()
        if not uri: return jsonify({"error":"URI required"}), 400
        if not uri.startswith(("http://","https://")): uri = "http://" + uri
        if not name: name = uri
        mime = "text/html"
    elif "file" in request.files:
        f = request.files["file"]
        if not f or not f.filename or not allowed_file(f.filename):
            return jsonify({"error":"Fichier invalide"}), 400
        safe  = secure_filename(f.filename)
        dest  = ASSETS_DIR / aid
        dest.mkdir(parents=True, exist_ok=True)
        fpath = dest / safe
        f.save(str(fpath))
        asset_type = detect_type(safe)
        mime  = mimetypes.guess_type(safe)[0] or ""
        md5   = md5_file(fpath)
        uri   = f"/assets_files/{aid}/{safe}"
        if not name: name = safe
    else:
        return jsonify({"error":"Aucun fichier ni URI"}), 400

    db = get_db()
    db.execute(
        """INSERT INTO assets
           (asset_id,name,uri,mimetype,asset_type,duration,play_for,
            is_active,md5,start_date,end_date,created_at,updated_at)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (aid,name,uri,mime,asset_type,duration,play_for,
         is_active,md5,start_date,end_date,now,now)
    )
    db.commit()
    row = db.execute("SELECT * FROM assets WHERE asset_id=?", (aid,)).fetchone()
    db.close()
    (BASE_DIR / "reload.flag").write_text("reload")
    return jsonify(dict(row)), 201

@app.route("/api/assets/<asset_id>", methods=["GET"])
@login_required
def api_asset_get(asset_id):
    db = get_db()
    row = db.execute("SELECT * FROM assets WHERE asset_id=?", (asset_id,)).fetchone()
    db.close()
    if not row: abort(404)
    return jsonify(dict(row))

@app.route("/api/assets/<asset_id>", methods=["PUT","PATCH"])
@login_required
def api_asset_update(asset_id):
    db = get_db()
    row = db.execute("SELECT * FROM assets WHERE asset_id=?", (asset_id,)).fetchone()
    if not row: db.close(); abort(404)
    data = request.get_json(silent=True) or {}
    name       = data.get("name",       row["name"])
    duration   = int(data.get("duration",  row["duration"]))
    is_active  = int(data.get("is_active", row["is_active"]))
    play_for   = data.get("play_for",   row["play_for"])
    start_date = data.get("start_date", row["start_date"])
    end_date   = data.get("end_date",   row["end_date"])
    db.execute(
        """UPDATE assets SET name=?,duration=?,is_active=?,play_for=?,
           start_date=?,end_date=?,updated_at=? WHERE asset_id=?""",
        (name,duration,is_active,play_for,start_date,end_date,now_iso(),asset_id)
    )
    db.commit()
    updated = db.execute("SELECT * FROM assets WHERE asset_id=?", (asset_id,)).fetchone()
    db.close()
    (BASE_DIR / "reload.flag").write_text("reload")
    return jsonify(dict(updated))

@app.route("/api/assets/<asset_id>", methods=["DELETE"])
@login_required
def api_asset_delete(asset_id):
    db = get_db()
    row = db.execute("SELECT * FROM assets WHERE asset_id=?", (asset_id,)).fetchone()
    if not row: db.close(); abort(404)
    if row["uri"].startswith("/assets_files/"):
        try:
            aid_from_uri = row["uri"].split("/")[2]
            import shutil
            asset_dir = ASSETS_DIR / aid_from_uri
            if asset_dir.exists():
                shutil.rmtree(str(asset_dir), ignore_errors=True)
        except Exception as e:
            log.warning("Suppression fichiers échouée : %s", e)
    db.execute("DELETE FROM schedule WHERE asset_id=?", (asset_id,))
    db.execute("DELETE FROM assets WHERE asset_id=?", (asset_id,))
    db.commit()
    db.close()
    (BASE_DIR / "reload.flag").write_text("reload")
    return jsonify({"deleted": asset_id})

# ── API Schedule ──────────────────────────────────────────────────────────────
@app.route("/api/schedule", methods=["GET"])
@login_required
def api_schedule_list():
    db = get_db()
    rows = db.execute("""
        SELECT s.*, a.name AS asset_name, a.asset_type
        FROM schedule s JOIN assets a ON a.asset_id=s.asset_id
        ORDER BY s.priority DESC, s.id ASC
    """).fetchall()
    db.close()
    return jsonify([dict(r) for r in rows])

@app.route("/api/schedule", methods=["POST"])
@login_required
def api_schedule_add():
    data = request.get_json(silent=True) or {}
    asset_id = data.get("asset_id","")
    if not asset_id: return jsonify({"error":"asset_id required"}), 400
    db = get_db()
    if not db.execute("SELECT asset_id FROM assets WHERE asset_id=?", (asset_id,)).fetchone():
        db.close(); return jsonify({"error":"Asset not found"}), 404
    db.execute(
        """INSERT INTO schedule
           (asset_id,name,start_date,end_date,start_time,end_time,days,priority,is_enabled)
           VALUES (?,?,?,?,?,?,?,?,?)""",
        (asset_id, data.get("name",""),
         data.get("start_date") or None, data.get("end_date") or None,
         data.get("start_time","00:00"), data.get("end_time","23:59"),
         data.get("days","1111111"), int(data.get("priority",0)),
         int(data.get("is_enabled",1)))
    )
    db.commit()
    sid = db.execute("SELECT last_insert_rowid() AS id").fetchone()["id"]
    row = db.execute("SELECT * FROM schedule WHERE id=?", (sid,)).fetchone()
    db.close()
    (BASE_DIR / "reload.flag").write_text("reload")
    return jsonify(dict(row)), 201

@app.route("/api/schedule/<int:sid>", methods=["DELETE"])
@login_required
def api_schedule_delete(sid):
    db = get_db()
    db.execute("DELETE FROM schedule WHERE id=?", (sid,))
    db.commit()
    db.close()
    (BASE_DIR / "reload.flag").write_text("reload")
    return jsonify({"deleted": sid})

# ── API Playlist ──────────────────────────────────────────────────────────────
@app.route("/api/playlist")
def api_playlist():
    db = get_db()
    assets = db.execute("SELECT * FROM assets WHERE is_active=1").fetchall()
    result = []
    for a in assets:
        schedules = db.execute(
            "SELECT * FROM schedule WHERE asset_id=? AND is_enabled=1", (a["asset_id"],)
        ).fetchall()
        if asset_plays_now(a, schedules):
            result.append(dict(a))
    db.close()
    if get_setting("shuffle_playlist","0") == "1":
        import random; random.shuffle(result)
    return jsonify(result)

@app.route("/api/settings")
def api_settings_public():
    keys = ["show_splash","default_duration","shuffle_playlist",
            "player_name","use_24h_clock","audio_output","first_run","display_rotate"]
    return jsonify({k: get_setting(k) for k in keys})

# ── API Users ─────────────────────────────────────────────────────────────────
@app.route("/api/users", methods=["GET"])
@admin_required
def api_users_list():
    db = get_db()
    rows = db.execute("SELECT id, username, role FROM users").fetchall()
    db.close()
    return jsonify([dict(r) for r in rows])

@app.route("/api/users", methods=["POST"])
@admin_required
def api_user_create():
    data = request.get_json(silent=True) or {}
    username = data.get("username","").strip()
    password = data.get("password","")
    role     = data.get("role","viewer")
    if not username or not password:
        return jsonify({"error":"username et password requis"}), 400
    if role not in ("admin","editor","viewer"): role = "viewer"
    db = get_db()
    try:
        db.execute(
            "INSERT INTO users (username, password, role) VALUES (?,?,?)",
            (username, generate_password_hash(password), role)
        )
        db.commit()
    except sqlite3.IntegrityError:
        db.close()
        return jsonify({"error":"Nom d'utilisateur déjà pris"}), 409
    uid = db.execute("SELECT last_insert_rowid() AS id").fetchone()["id"]
    db.close()
    return jsonify({"id":uid,"username":username,"role":role}), 201

@app.route("/api/users/<int:uid>", methods=["DELETE"])
@admin_required
def api_user_delete(uid):
    if uid == session.get("user_id"):
        return jsonify({"error":"Impossible de se supprimer soi-même"}), 400
    db = get_db()
    db.execute("DELETE FROM users WHERE id=?", (uid,))
    db.commit()
    db.close()
    return jsonify({"deleted": uid})

@app.route("/api/users/<int:uid>/password", methods=["PUT"])
@admin_required
def api_user_password(uid):
    data = request.get_json(silent=True) or {}
    new_password = data.get("password","")
    if not new_password or len(new_password) < 4:
        return jsonify({"error":"Mot de passe trop court (min 4 caractères)"}), 400
    db = get_db()
    db.execute("UPDATE users SET password=? WHERE id=?",
               (generate_password_hash(new_password), uid))
    db.commit()
    db.close()
    return jsonify({"updated": uid})

@app.route("/api/users/me/password", methods=["PUT"])
@login_required
def api_my_password():
    data = request.get_json(silent=True) or {}
    current  = data.get("current_password","")
    new_pass = data.get("new_password","")
    if not new_pass or len(new_pass) < 4:
        return jsonify({"error":"Nouveau mot de passe trop court"}), 400
    db = get_db()
    user = db.execute("SELECT * FROM users WHERE id=?", (session["user_id"],)).fetchone()
    if not user or not check_password_hash(user["password"], current):
        db.close()
        return jsonify({"error":"Mot de passe actuel incorrect"}), 401
    db.execute("UPDATE users SET password=? WHERE id=?",
               (generate_password_hash(new_pass), session["user_id"]))
    db.commit()
    db.close()
    return jsonify({"updated": session["user_id"]})

# ── API Système ───────────────────────────────────────────────────────────────
@app.route("/api/system/reboot", methods=["POST"])
@admin_required
def api_reboot():
    subprocess.Popen(["sudo","reboot"])
    return jsonify({"status":"rebooting"})

@app.route("/api/system/reload_viewer", methods=["POST"])
@login_required
def api_reload_viewer():
    data = request.get_json(silent=True) or {}
    direction = data.get("direction","reload")
    (BASE_DIR / "reload.flag").write_text(direction)
    return jsonify({"status":"reload_requested","direction":direction})

@app.route("/api/system/info")
@login_required
def api_system_info():
    return jsonify(_get_system_info())

@app.route("/api/system/scan_wifi")
@admin_required
def api_scan_wifi():
    try:
        out = subprocess.check_output(
            ["iwlist","wlan0","scan"], text=True, timeout=10,
            stderr=subprocess.DEVNULL
        )
        networks = []
        current  = {}
        for line in out.split("\n"):
            line = line.strip()
            if "ESSID:" in line:
                ssid = line.split('"')[1] if '"' in line else ""
                if ssid:
                    current["ssid"] = ssid
                    networks.append(current)
                    current = {}
            elif "Quality=" in line:
                try:
                    q = line.split("Quality=")[1].split(" ")[0]
                    num, den = q.split("/")
                    current["quality"] = int(int(num)*100/int(den))
                except Exception:
                    current["quality"] = 0
            elif "Encryption key:on" in line:
                current["encrypted"] = True
        seen   = set()
        unique = []
        for n in networks:
            if n.get("ssid") and n["ssid"] not in seen:
                seen.add(n["ssid"]); unique.append(n)
        return jsonify(sorted(unique, key=lambda x: x.get("quality",0), reverse=True))
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/api/system/connect_wifi", methods=["POST"])
@admin_required
def api_connect_wifi():
    data = request.get_json(silent=True) or {}
    ssid = data.get("ssid","").strip()
    pwd  = data.get("password","")
    if not ssid: return jsonify({"error":"SSID requis"}), 400
    try:
        result = subprocess.check_output(
            ["sudo","/opt/thyra/scripts/wifi_connect.sh", ssid, pwd],
            text=True, timeout=30,
            stderr=subprocess.STDOUT
        )
        connected_line = next(
            (l for l in result.splitlines() if l.startswith("connected:")), None
        )
        if connected_line:
            ip = connected_line.split(":",1)[1].strip()
            set_setting("first_run","0")
            set_setting("ap_enabled","0")
            return jsonify({"status":"connected","ip":ip})
        return jsonify({"status":"error","detail":result.strip()}), 500
    except subprocess.TimeoutExpired:
        return jsonify({"status":"timeout","detail":"Connexion WiFi trop longue (>30s)"}), 504
    except subprocess.CalledProcessError as e:
        return jsonify({"status":"error","detail": e.output or str(e)}), 500
    except Exception as e:
        return jsonify({"status":"error","detail":str(e)}), 500

# ── Portail captif ────────────────────────────────────────────────────────────
try:
    from ap_routes import register_ap_routes as _reg_ap
    _reg_ap(app, get_setting, set_setting)
    log.info("Routes portail captif enregistrées")
except ImportError:
    log.warning("ap_routes.py absent")

# ── Static assets ─────────────────────────────────────────────────────────────
@app.route("/assets_files/<asset_id>/<filename>")
def serve_asset_file(asset_id, filename):
    return send_from_directory(str(ASSETS_DIR / asset_id), filename)

# ── Entrypoint ────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    init_db()
    app.run(host="127.0.0.1", port=5000, debug=False)
