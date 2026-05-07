#!/usr/bin/env bash
# =============================================================================
# Thyra — Script d'installation bare-metal v2
# Compatible: Raspberry Pi OS Bullseye/Bookworm (32/64bit), Debian 11/12, Ubuntu 22/24
# Architecture: armhf, arm64, x86_64
# Usage: sudo bash <(curl -fsSL https://raw.githubusercontent.com/ashd0wn/thyra/main/deploy.sh)
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
CYN='\033[0;36m'; BLD='\033[1m';    RST='\033[0m'

THYRA_HOME="/opt/thyra"
THYRA_USER="thyra"
THYRA_REPO="${THYRA_REPO:-https://github.com/ashd0wn/thyra}"
THYRA_BRANCH="${THYRA_BRANCH:-main}"
LOG_FILE="/tmp/thyra_install_$(date +%Y%m%d_%H%M%S).log"

IS_RPI=false
HAS_WIFI=false
HAS_ETH=false
RPI_MODEL=""
ARCH=""

log()     { echo -e "${CYN}[$(date '+%H:%M:%S')]${RST} $*" | tee -a "$LOG_FILE"; }
ok()      { echo -e "${GRN}  ✓ $*${RST}"                   | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YEL}  ⚠ $*${RST}"                   | tee -a "$LOG_FILE"; }
err()     { echo -e "${RED}  ✗ $*${RST}" >&2               | tee -a "$LOG_FILE"; }
die()     { err "$*"; exit 1; }
section() { echo -e "\n${BLD}${CYN}══ $* ══${RST}" | tee -a "$LOG_FILE"; }
pkg_exists() { apt-cache show "$1" &>/dev/null 2>&1; }

print_banner() {
    echo -e "${CYN}"
    cat <<'EOF'
  _____ _
 |_   _| |__  _   _ _ __ __ _
   | | | '_ \| | | | '__/ _` |
   | | | | | | |_| | | | (_| |
   |_| |_| |_|\__, |_|  \__,_|
              |___/
   θύρα — Bare-metal Digital Signage
EOF
    echo -e "${RST}"
    echo -e "  Log : ${YEL}${LOG_FILE}${RST}\n"
}

check_root() {
    [[ $EUID -eq 0 ]] || die "Exécuter en root : sudo bash deploy.sh"
}

check_os() {
    [[ -f /etc/os-release ]] || die "Impossible de détecter l'OS"
    . /etc/os-release
    case "${ID:-unknown}" in
        raspbian|debian|ubuntu) ok "OS : $PRETTY_NAME" ;;
        *) warn "OS non officiel : $PRETTY_NAME" ;;
    esac
    ARCH=$(uname -m)
    ok "Architecture : $ARCH"
}

check_network() {
    ping -c1 -W3 8.8.8.8 &>/dev/null || ping -c1 -W3 1.1.1.1 &>/dev/null \
        || die "Pas de connexion internet."
    ok "Réseau OK"
}

detect_hardware() {
    section "Détection du matériel"

    if [[ -f /proc/device-tree/model ]]; then
        RPI_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "")
        if echo "$RPI_MODEL" | grep -qi "raspberry"; then
            IS_RPI=true
            ok "Raspberry Pi : $RPI_MODEL"
        fi
    fi

    if [[ -d /sys/class/net/wlan0 ]] || ip link show wlan0 &>/dev/null 2>&1; then
        HAS_WIFI=true
        ok "WiFi détecté (wlan0)"
    else
        warn "Pas de WiFi détecté"
    fi

    if ip route | grep -q "^default.*eth0" 2>/dev/null; then
        HAS_ETH=true
        ok "Ethernet actif (eth0)"
    elif ip addr show eth0 2>/dev/null | grep -q "inet "; then
        HAS_ETH=true
        ok "Ethernet avec IP (eth0)"
    else
        warn "Ethernet inactif — portail captif sera activé automatiquement au boot"
    fi

    local mem_mb
    mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
    if [[ $mem_mb -lt 512 ]]; then
        warn "RAM : ${mem_mb} MB (faible)"
    else
        ok "RAM : ${mem_mb} MB"
    fi
}

install_packages() {
    section "Installation des paquets système"

    log "Mise à jour APT…"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >> "$LOG_FILE" 2>&1

    log "Paquets de base…"
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        python3 python3-pip python3-venv python3-dev \
        build-essential libffi-dev libssl-dev libsqlite3-dev \
        nginx supervisor \
        curl wget git sqlite3 net-tools iproute2 bc unzip rsync jq \
        imagemagick vlc vlc-bin \
        xserver-xorg-core x11-xserver-utils xinit openbox xdotool \
        fonts-liberation fonts-dejavu-core \
        feh qrencode \
        >> "$LOG_FILE" 2>&1
    ok "Paquets de base installés"

    log "Pilote X11…"
    if $IS_RPI; then
        pkg_exists xserver-xorg-video-fbdev && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y xserver-xorg-video-fbdev >> "$LOG_FILE" 2>&1 || true
    else
        pkg_exists xserver-xorg-video-all && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y xserver-xorg-video-all >> "$LOG_FILE" 2>&1 || true
    fi
    ok "Pilote X11 OK"

    log "Chromium…"
    if pkg_exists chromium; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y chromium >> "$LOG_FILE" 2>&1
        ok "chromium installé"
    elif pkg_exists chromium-browser; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y chromium-browser >> "$LOG_FILE" 2>&1
        ok "chromium-browser installé"
    else
        warn "Chromium non trouvé dans APT — assets web désactivés"
    fi

    if $HAS_WIFI; then
        log "Paquets portail captif…"
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            hostapd dnsmasq iptables wireless-tools iw \
            >> "$LOG_FILE" 2>&1
        pkg_exists iptables-persistent && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >> "$LOG_FILE" 2>&1 || true
        ok "Paquets AP installés"
    fi

    if $IS_RPI; then
        log "Paquets Raspberry Pi…"
        pkg_exists raspi-config && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y raspi-config >> "$LOG_FILE" 2>&1 || true
        pkg_exists python3-rpi.gpio && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y python3-rpi.gpio >> "$LOG_FILE" 2>&1 || true
        pkg_exists unclutter && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y unclutter >> "$LOG_FILE" 2>&1 || true
        ok "Paquets Pi installés"
    fi

    ok "Tous les paquets installés"
}

create_user() {
    section "Utilisateur système"

    if ! id "$THYRA_USER" &>/dev/null; then
        useradd --system --create-home --home-dir "/home/$THYRA_USER" \
                --shell /bin/bash "$THYRA_USER" >> "$LOG_FILE" 2>&1
        ok "Utilisateur $THYRA_USER créé"
    else
        ok "Utilisateur $THYRA_USER existe déjà"
    fi

    for grp in video audio input dialout tty render plugdev; do
        getent group "$grp" &>/dev/null && usermod -aG "$grp" "$THYRA_USER" 2>/dev/null || true
    done

    touch "/home/$THYRA_USER/.Xauthority" 2>/dev/null || true
    chown "$THYRA_USER:$THYRA_USER" "/home/$THYRA_USER/.Xauthority" 2>/dev/null || true
    ok "Groupes et .Xauthority configurés"
}

create_directories() {
    section "Arborescence"

    for d in \
        "$THYRA_HOME" "$THYRA_HOME/app" "$THYRA_HOME/assets" \
        "$THYRA_HOME/db" "$THYRA_HOME/static/css" "$THYRA_HOME/static/js" \
        "$THYRA_HOME/static/img" "$THYRA_HOME/templates" \
        "$THYRA_HOME/scripts" "$THYRA_HOME/backups" \
        "/var/log/thyra"
    do
        mkdir -p "$d"
    done

    chown -R "$THYRA_USER:$THYRA_USER" "$THYRA_HOME" "/var/log/thyra"
    ok "Arborescence créée dans $THYRA_HOME"
}

install_app_code() {
    section "Code applicatif"

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ -f "$SCRIPT_DIR/app/server.py" ]]; then
        log "Copie depuis source locale…"
        cp -r "$SCRIPT_DIR/app/."       "$THYRA_HOME/app/"
        cp -r "$SCRIPT_DIR/templates/." "$THYRA_HOME/templates/"
        cp -r "$SCRIPT_DIR/static/."    "$THYRA_HOME/static/"
        cp -r "$SCRIPT_DIR/scripts/."   "$THYRA_HOME/scripts/"
        ok "Code local copié"
    else
        log "Clonage depuis GitHub…"
        rm -rf /tmp/thyra_src
        git clone --depth 1 --branch "$THYRA_BRANCH" "$THYRA_REPO" /tmp/thyra_src >> "$LOG_FILE" 2>&1
        cp -r /tmp/thyra_src/app/.       "$THYRA_HOME/app/"
        cp -r /tmp/thyra_src/templates/. "$THYRA_HOME/templates/"
        cp -r /tmp/thyra_src/static/.    "$THYRA_HOME/static/"
        cp -r /tmp/thyra_src/scripts/.   "$THYRA_HOME/scripts/"
        rm -rf /tmp/thyra_src
        ok "Code GitHub cloné"
    fi

    chown -R "$THYRA_USER:$THYRA_USER" \
        "$THYRA_HOME/app" "$THYRA_HOME/templates" \
        "$THYRA_HOME/static" "$THYRA_HOME/scripts"
    chmod +x "$THYRA_HOME/scripts/"*.sh 2>/dev/null || true
}

setup_python_venv() {
    section "Environnement Python"

    sudo -u "$THYRA_USER" python3 -m venv "$THYRA_HOME/venv" >> "$LOG_FILE" 2>&1
    local PIP="$THYRA_HOME/venv/bin/pip"
    sudo -u "$THYRA_USER" "$PIP" install --upgrade pip setuptools wheel >> "$LOG_FILE" 2>&1

    cat > "$THYRA_HOME/requirements.txt" <<'REQS'
flask>=2.3,<4
gunicorn>=21
werkzeug>=2.3
requests>=2.31
Pillow>=10.0
qrcode>=7.4
REQS

    sudo -u "$THYRA_USER" "$PIP" install -r "$THYRA_HOME/requirements.txt" >> "$LOG_FILE" 2>&1
    ok "Venv Python prêt"
}

init_database() {
    section "Base de données"

    sudo -u "$THYRA_USER" \
        THYRA_HOME="$THYRA_HOME" \
        "$THYRA_HOME/venv/bin/python3" -c "
import sys, os
sys.path.insert(0, '$THYRA_HOME/app')
os.environ['THYRA_HOME'] = '$THYRA_HOME'
from server import init_db; init_db(); print('DB OK')
" >> "$LOG_FILE" 2>&1
    ok "SQLite initialisé"

    # Droits corrects sur la DB + désactivation WAL (évite les problèmes d'écriture)
    sqlite3 "$THYRA_HOME/db/thyra.db" "PRAGMA journal_mode=DELETE;" >> "$LOG_FILE" 2>&1 || true
    chmod 664 "$THYRA_HOME/db/thyra.db"
    chmod 775 "$THYRA_HOME/db/"
    chown -R "$THYRA_USER:$THYRA_USER" "$THYRA_HOME/db"
    ok "Droits DB configurés"
}

configure_nginx() {
    section "Nginx"

    cat > /etc/nginx/sites-available/thyra <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    client_max_body_size 1G;
    client_body_timeout 600s;
    send_timeout 600s;
    gzip on;
    gzip_types text/plain text/css application/javascript application/json image/svg+xml;
    location /static/ {
        alias ${THYRA_HOME}/static/;
        expires 7d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }
    location /assets_files/ {
        alias ${THYRA_HOME}/assets/;
        expires 1h;
        add_header Accept-Ranges bytes;
        access_log off;
    }
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 600s;
        proxy_buffering off;
        proxy_request_buffering off;
    }
    access_log /var/log/nginx/thyra_access.log;
    error_log  /var/log/nginx/thyra_error.log warn;
}
NGINX

    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/thyra /etc/nginx/sites-enabled/thyra
    nginx -t >> "$LOG_FILE" 2>&1 || { err "Config Nginx invalide"; return 1; }
    systemctl enable nginx  >> "$LOG_FILE" 2>&1
    systemctl restart nginx >> "$LOG_FILE" 2>&1
    ok "Nginx configuré"
}

configure_supervisor() {
    section "Supervisord"

    cat > /etc/supervisor/conf.d/thyra.conf <<SUPCONF
[program:thyra-server]
command=${THYRA_HOME}/venv/bin/gunicorn --workers 2 --worker-class sync --bind 127.0.0.1:5000 --timeout 120 --keep-alive 5 --access-logfile /var/log/thyra/gunicorn_access.log --error-logfile /var/log/thyra/gunicorn_error.log server:app
directory=${THYRA_HOME}/app
user=${THYRA_USER}
environment=THYRA_HOME="${THYRA_HOME}",THYRA_USER="${THYRA_USER}"
autostart=true
autorestart=true
startsecs=3
startretries=5
stopasgroup=true
killasgroup=true
stdout_logfile=/var/log/thyra/server_stdout.log
stderr_logfile=/var/log/thyra/server_stderr.log

[program:thyra-x11]
command=/bin/bash -c "rm -f /tmp/.X0-lock /tmp/.X11-unix/X0; exec /usr/bin/Xorg :0 -nocursor vt1 -nolisten tcp"
user=root
priority=10
autostart=true
autorestart=true
startsecs=3
startretries=5
stdout_logfile=/var/log/thyra/x11_stdout.log
stderr_logfile=/var/log/thyra/x11_stderr.log

[program:thyra-viewer]
command=${THYRA_HOME}/venv/bin/python3 ${THYRA_HOME}/app/viewer.py
directory=${THYRA_HOME}/app
user=${THYRA_USER}
environment=THYRA_HOME="${THYRA_HOME}",THYRA_USER="${THYRA_USER}",DISPLAY=":0",XAUTHORITY="/home/${THYRA_USER}/.Xauthority"
priority=20
autostart=true
autorestart=true
startsecs=10
startretries=10
stopasgroup=true
killasgroup=true
stdout_logfile=/var/log/thyra/viewer_stdout.log
stderr_logfile=/var/log/thyra/viewer_stderr.log

[program:thyra-watchdog]
command=${THYRA_HOME}/scripts/watchdog.sh
user=root
priority=30
autostart=true
autorestart=true
startsecs=5
stdout_logfile=/var/log/thyra/watchdog.log
stderr_logfile=/var/log/thyra/watchdog.log

[program:thyra-ap]
command=${THYRA_HOME}/scripts/ap_manager.sh run
user=root
priority=40
autostart=false
autorestart=false
stdout_logfile=/var/log/thyra/ap.log
stderr_logfile=/var/log/thyra/ap.log
SUPCONF

    systemctl enable supervisor >> "$LOG_FILE" 2>&1
    systemctl restart supervisor >> "$LOG_FILE" 2>&1
    sleep 2
    supervisorctl reread >> "$LOG_FILE" 2>&1
    supervisorctl update >> "$LOG_FILE" 2>&1

    # Socket supervisor accessible au groupe thyra (pour System Info)
    if grep -q "^\[unix_http_server\]" /etc/supervisor/supervisord.conf; then
        sed -i '/^\[unix_http_server\]/,/^\[/{
            s|^chmod=.*|chmod=0770|
            s|^chown=.*|chown=root:thyra|
            /^chmod=0770/{ /chown=/!a\chown=root:thyra
 }
        }' /etc/supervisor/supervisord.conf 2>/dev/null || true
    fi
    # Ajoute thyra à son propre groupe (pour accès socket)
    usermod -aG "$THYRA_USER" "$THYRA_USER" 2>/dev/null || true
    systemctl restart supervisor >> "$LOG_FILE" 2>&1
    ok "Supervisord configuré"
}

configure_sudo() {
    section "Règles sudo"
    cat > /etc/sudoers.d/thyra <<'SUDOERS'
thyra ALL=(root) NOPASSWD: /opt/thyra/scripts/ap_manager.sh
thyra ALL=(root) NOPASSWD: /opt/thyra/scripts/wifi_connect.sh
thyra ALL=(root) NOPASSWD: /sbin/reboot
thyra ALL=(root) NOPASSWD: /usr/bin/supervisorctl
thyra ALL=(root) NOPASSWD: /usr/sbin/raspi-config
SUDOERS
    chmod 440 /etc/sudoers.d/thyra
    ok "Règles sudo configurées"
}

configure_display_rpi() {
    section "Configuration affichage Raspberry Pi"

    local CONFIG_TXT="/boot/config.txt"
    [[ -f /boot/firmware/config.txt ]] && CONFIG_TXT="/boot/firmware/config.txt"

    if [[ ! -f "$CONFIG_TXT" ]]; then
        warn "$CONFIG_TXT introuvable"
        return
    fi

    # HDMI force hotplug
    grep -q "^hdmi_force_hotplug" "$CONFIG_TXT" \
        && sed -i 's/^hdmi_force_hotplug=.*/hdmi_force_hotplug=1/' "$CONFIG_TXT" \
        || echo "hdmi_force_hotplug=1" >> "$CONFIG_TXT"
    ok "hdmi_force_hotplug=1"

    # HDMI 1080p par défaut
    grep -q "^hdmi_group" "$CONFIG_TXT" || echo "hdmi_group=2" >> "$CONFIG_TXT"
    grep -q "^hdmi_mode"  "$CONFIG_TXT" || echo "hdmi_mode=82"  >> "$CONFIG_TXT"
    ok "HDMI 1080p (group=2 mode=82)"

    # Overscan désactivé
    grep -q "^disable_overscan" "$CONFIG_TXT" \
        && sed -i 's/^disable_overscan=.*/disable_overscan=1/' "$CONFIG_TXT" \
        || echo "disable_overscan=1" >> "$CONFIG_TXT"
    ok "Overscan désactivé"

    # CMA memory : remplace gpu_mem (incompatible avec le pilote KMS/DRM sur Pi OS Bookworm)
    # gpu_mem= est ignoré sur Pi 4/5 64bit et provoque des conflits avec le CMA
    local mem_mb cma_size
    mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
    if   [[ $mem_mb -ge 4096 ]]; then cma_size="512M"   # Pi 4 4GB / Pi 4 8GB
    elif [[ $mem_mb -ge 2048 ]]; then cma_size="256M"   # Pi 4 2GB
    else                               cma_size="256M"   # Pi 3 1GB
    fi
    # Supprime gpu_mem si présent (conflict avec CMA)
    sed -i '/^gpu_mem=/d' "$CONFIG_TXT" 2>/dev/null || true
    # Ajoute ou met à jour cma-size
    grep -q "^dtparam=cma-size=" "$CONFIG_TXT" \
        && sed -i "s/^dtparam=cma-size=.*/dtparam=cma-size=${cma_size}/" "$CONFIG_TXT" \
        || echo "dtparam=cma-size=${cma_size}" >> "$CONFIG_TXT"
    ok "CMA memory : ${cma_size} (RAM totale : ${mem_mb} MB)"

    # Blanking et consoleblank
    if command -v raspi-config &>/dev/null; then
        raspi-config nonint do_blanking 1 >> "$LOG_FILE" 2>&1 \
            && ok "Blanking désactivé (raspi-config)" || true
    fi

    local CMDLINE="/boot/cmdline.txt"
    [[ -f /boot/firmware/cmdline.txt ]] && CMDLINE="/boot/firmware/cmdline.txt"
    if [[ -f "$CMDLINE" ]]; then
        grep -q "consoleblank=0" "$CMDLINE" \
            || sed -i 's/$/ consoleblank=0/' "$CMDLINE"
        ok "consoleblank=0"
    fi

    ok "Configuration affichage Pi terminée ($CONFIG_TXT)"
}

disable_desktop_session() {
    section "Désactivation session graphique"

    # LightDM (Pi OS avec bureau, Ubuntu)
    if systemctl is-enabled lightdm &>/dev/null 2>&1; then
        systemctl disable lightdm >> "$LOG_FILE" 2>&1
        systemctl stop    lightdm >> "$LOG_FILE" 2>&1
        ok "LightDM désactivé"
    fi

    # GDM3 (GNOME)
    if systemctl is-enabled gdm3 &>/dev/null 2>&1; then
        systemctl disable gdm3 >> "$LOG_FILE" 2>&1
        systemctl stop    gdm3 >> "$LOG_FILE" 2>&1
        ok "GDM3 désactivé"
    fi

    # SDDM (KDE/LXQT)
    if systemctl is-enabled sddm &>/dev/null 2>&1; then
        systemctl disable sddm >> "$LOG_FILE" 2>&1
        systemctl stop    sddm >> "$LOG_FILE" 2>&1
        ok "SDDM désactivé"
    fi

    # Passer en multi-user (sans GUI)
    systemctl set-default multi-user.target >> "$LOG_FILE" 2>&1
    ok "Target : multi-user.target (console)"

    # raspi-config : boot console autologin (B2)
    if $IS_RPI && command -v raspi-config &>/dev/null; then
        raspi-config nonint do_boot_behaviour B2 >> "$LOG_FILE" 2>&1 \
            && ok "raspi-config : boot console autologin" || true
    fi

    ok "Session graphique bureau désactivée — Thyra gère X11"
}

configure_openbox() {
    section "Openbox / X11"

    local OB_DIR="/home/$THYRA_USER/.config/openbox"
    mkdir -p "$OB_DIR"

    cat > "$OB_DIR/autostart" <<'OB'
#!/bin/bash
xset s off
xset s noblank
xset -dpms
xrandr --auto
command -v unclutter &>/dev/null && unclutter -idle 0 -root &
OB
    chmod +x "$OB_DIR/autostart"

    cat > "$OB_DIR/rc.xml" <<'OBRC'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <theme>
    <name>Clearlooks</name>
    <keepBorder>no</keepBorder>
    <animateIconify>no</animateIconify>
    <font place="ActiveWindow"><name>sans</name><size>8</size></font>
  </theme>
  <desktops><number>1</number></desktops>
  <applications>
    <application class="*">
      <decor>no</decor>
      <maximized>true</maximized>
    </application>
  </applications>
</openbox_config>
OBRC

    chown -R "$THYRA_USER:$THYRA_USER" "/home/$THYRA_USER/.config"

    if [[ -f /etc/X11/Xwrapper.config ]]; then
        sed -i 's/^allowed_users=.*/allowed_users=anybody/' /etc/X11/Xwrapper.config
    else
        mkdir -p /etc/X11
        printf 'allowed_users=anybody\nneeds_root_rights=yes\n' > /etc/X11/Xwrapper.config
    fi

    ok "Openbox et Xwrapper configurés"
}

configure_autologin() {
    section "Autologin tty1"

    if systemctl cat getty@tty1 &>/dev/null 2>&1; then
        mkdir -p /etc/systemd/system/getty@tty1.service.d
        cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<ALOG
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${THYRA_USER} --noclear %I \$TERM
ALOG
        systemctl daemon-reload >> "$LOG_FILE" 2>&1
        ok "Autologin tty1 → $THYRA_USER"
    else
        warn "getty@tty1 introuvable"
    fi
}

configure_initial_ap() {
    section "Configuration initiale portail captif WiFi"

    if ! $HAS_WIFI; then
        warn "Pas de WiFi — portail captif ignoré"
        return
    fi

    local RAND_SUFFIX
    RAND_SUFFIX=$(tr -dc 'A-F0-9' < /dev/urandom | head -c4)
    local AP_SSID="Thyra-${RAND_SUFFIX}"
    local AP_PASS
    AP_PASS=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c12)

    sqlite3 "$THYRA_HOME/db/thyra.db" \
        "UPDATE settings SET value='${AP_SSID}' WHERE key='ap_ssid';" 2>/dev/null || true
    sqlite3 "$THYRA_HOME/db/thyra.db" \
        "UPDATE settings SET value='${AP_PASS}' WHERE key='ap_password';" 2>/dev/null || true

    if ! $HAS_ETH; then
        sqlite3 "$THYRA_HOME/db/thyra.db" \
            "UPDATE settings SET value='1' WHERE key='ap_enabled';" 2>/dev/null || true
        ok "AP activé automatiquement (pas d'Ethernet)"
    fi

    if command -v qrencode &>/dev/null; then
        local WIFI_QR="WIFI:T:WPA;S:${AP_SSID};P:${AP_PASS};;"
        qrencode -t PNG -s 6 -m 2 -o "$THYRA_HOME/static/img/wifi_qr.png" "$WIFI_QR" \
            2>/dev/null && ok "QR code WiFi généré" || warn "QR code échec"
    fi

    cat > "$THYRA_HOME/wifi_credentials.txt" <<CREDS
Thyra — Identifiants WiFi générés à l'installation
===================================================
SSID     : ${AP_SSID}
Password : ${AP_PASS}
IP       : 192.168.73.1
Interface: http://192.168.73.1/
===================================================
Modifiables dans : Paramètres → Portail captif WiFi
CREDS
    chown "$THYRA_USER:$THYRA_USER" "$THYRA_HOME/wifi_credentials.txt"
    chmod 600 "$THYRA_HOME/wifi_credentials.txt"

    ok "AP configuré : SSID=${AP_SSID} / Pass=${AP_PASS}"
}

create_wifi_connect_script() {
    section "Script connexion WiFi"

    cat > "$THYRA_HOME/scripts/wifi_connect.sh" <<'WIFISCRIPT'
#!/usr/bin/env bash
# wifi_connect.sh — Connecte le Pi à un réseau WiFi (wizard first-run)
set -euo pipefail
SSID="${1:-}"
PASS="${2:-}"
[[ -z "$SSID" ]] && { echo "Usage: $0 <ssid> <password>"; exit 1; }

/opt/thyra/scripts/ap_manager.sh stop 2>/dev/null || true
sleep 1

if command -v nmcli &>/dev/null; then
    nmcli device wifi connect "$SSID" password "$PASS" 2>&1 || true
    sleep 4
    IP=$(nmcli -g IP4.ADDRESS device show wlan0 2>/dev/null | head -1 | cut -d/ -f1 || echo "")
    echo "connected:${IP}"
elif command -v wpa_cli &>/dev/null; then
    wpa_passphrase "$SSID" "$PASS" >> /etc/wpa_supplicant/wpa_supplicant.conf
    wpa_cli -i wlan0 reconfigure
    sleep 6
    IP=$(ip route get 1 | awk '{print $7; exit}' 2>/dev/null || hostname -I | awk '{print $1}')
    echo "connected:${IP}"
else
    echo "error:no wifi manager"
    exit 1
fi
WIFISCRIPT

    chmod +x "$THYRA_HOME/scripts/wifi_connect.sh"
    chown root:root "$THYRA_HOME/scripts/wifi_connect.sh"
    ok "wifi_connect.sh créé"
}

generate_splash() {
    section "Splash screen"

    # Génère le splash via gen_splash.py (IP + QR code)
    if [[ -f "$THYRA_HOME/scripts/gen_splash.py" ]]; then
        sudo -u "$THYRA_USER" \
            THYRA_HOME="$THYRA_HOME" \
            "$THYRA_HOME/venv/bin/python3" "$THYRA_HOME/scripts/gen_splash.py" \
            >> "$LOG_FILE" 2>&1 \
            && ok "Splash généré avec IP et QR code" \
            || warn "gen_splash.py échoué — splash SVG utilisé en fallback"
    fi

    # Fallback SVG si PNG non généré
    local SPLASH_SVG="$THYRA_HOME/static/img/splash.svg"
    local SPLASH_PNG="$THYRA_HOME/static/img/splash.png"
    if [[ ! -f "$SPLASH_PNG" ]]; then
        cat > "$SPLASH_SVG" <<'SPLASHSVG'
<svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080">
  <rect width="1920" height="1080" fill="#0f0f13"/>
  <text x="960" y="400" font-family="sans-serif" font-size="96"
        font-weight="bold" fill="#6366f1" text-anchor="middle">Thyra</text>
  <text x="960" y="480" font-family="sans-serif" font-size="28"
        fill="#818cf8" text-anchor="middle">θύρα · Digital Signage</text>
  <text x="960" y="600" font-family="sans-serif" font-size="24"
        fill="#6b6b8a" text-anchor="middle">Démarrage en cours…</text>
</svg>
SPLASHSVG
        chown "$THYRA_USER:$THYRA_USER" "$SPLASH_SVG" 2>/dev/null || true
        warn "Splash PNG non généré — SVG utilisé"
    fi

    # Service systemd pour régénérer le splash au boot avec l'IP courante
    cat > /etc/systemd/system/thyra-splash.service <<SPLASHSVC
[Unit]
Description=Thyra splash screen generator
After=network.target thyra-server.service
Wants=network.target

[Service]
Type=oneshot
ExecStart=/opt/thyra/venv/bin/python3 /opt/thyra/scripts/gen_splash.py
User=${THYRA_USER}
Environment=THYRA_HOME=${THYRA_HOME}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SPLASHSVC
    systemctl daemon-reload >> "$LOG_FILE" 2>&1
    systemctl enable thyra-splash >> "$LOG_FILE" 2>&1
    ok "Service splash au boot configuré"
}

install_boot_network_check() {
    section "Service netcheck (AP fallback)"

    chmod +x "$THYRA_HOME/scripts/boot_network_check.sh"

    cat > /etc/systemd/system/thyra-netcheck.service <<NETSVC
[Unit]
Description=Thyra network check — auto AP fallback
After=network.target supervisor.service
Wants=network.target

[Service]
Type=oneshot
ExecStart=/opt/thyra/scripts/boot_network_check.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
NETSVC
    systemctl daemon-reload >> "$LOG_FILE" 2>&1
    systemctl enable thyra-netcheck >> "$LOG_FILE" 2>&1
    ok "Service thyra-netcheck configuré"
}



start_services() {
    section "Démarrage des services"

    supervisorctl reload >> "$LOG_FILE" 2>&1 || true
    sleep 2

    supervisorctl start thyra-server   >> "$LOG_FILE" 2>&1 && ok "thyra-server démarré"
    sleep 5

    supervisorctl start thyra-x11      >> "$LOG_FILE" 2>&1 && ok "thyra-x11 démarré" || warn "X11 non démarré"
    sleep 2

    supervisorctl start thyra-viewer   >> "$LOG_FILE" 2>&1 && ok "thyra-viewer démarré" || warn "Viewer non démarré"
    supervisorctl start thyra-watchdog >> "$LOG_FILE" 2>&1 || true

    local ap_enabled
    ap_enabled=$(sqlite3 "$THYRA_HOME/db/thyra.db" \
        "SELECT value FROM settings WHERE key='ap_enabled';" 2>/dev/null || echo "0")
    if [[ "$ap_enabled" == "1" ]] && $HAS_WIFI; then
        supervisorctl start thyra-ap >> "$LOG_FILE" 2>&1 && ok "thyra-ap démarré" || true
    fi
}

verify_installation() {
    section "Vérification"

    local ok_count=0
    for attempt in $(seq 1 15); do
        if curl -sf --max-time 3 http://127.0.0.1:5000/api/settings &>/dev/null; then
            ok "API Flask répond"
            ok_count=$((ok_count+1))
            break
        fi
        log "  API non prête ($attempt/15)…"; sleep 3
    done

    if curl -sf --max-time 3 http://127.0.0.1/ &>/dev/null; then
        ok "Nginx répond"
        ok_count=$((ok_count+1))
    fi

    log "Statut supervisord :"
    supervisorctl status 2>/dev/null | tee -a "$LOG_FILE" || true
    [[ $ok_count -ge 2 ]] && ok "Installation vérifiée !" || warn "Vérification partielle — voir $LOG_FILE"
}

print_summary() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    local ap_ssid ap_pass ap_enabled
    ap_ssid=$(sqlite3 "$THYRA_HOME/db/thyra.db" "SELECT value FROM settings WHERE key='ap_ssid';" 2>/dev/null || echo "Thyra-????")
    ap_pass=$(sqlite3 "$THYRA_HOME/db/thyra.db"  "SELECT value FROM settings WHERE key='ap_password';" 2>/dev/null || echo "????????")
    ap_enabled=$(sqlite3 "$THYRA_HOME/db/thyra.db" "SELECT value FROM settings WHERE key='ap_enabled';" 2>/dev/null || echo "0")

    echo ""
    echo -e "${GRN}${BLD}╔══════════════════════════════════════════════════════════╗${RST}"
    echo -e "${GRN}${BLD}║            Thyra installé avec succès !                 ║${RST}"
    echo -e "${GRN}${BLD}╚══════════════════════════════════════════════════════════╝${RST}"
    echo ""
    echo -e "  ${BLD}Interface web :${RST}  ${CYN}http://${ip}/${RST}"
    echo -e "  ${BLD}Login :${RST}          admin / admin  ${RED}← CHANGEZ-LE !${RST}"
    echo ""
    if $HAS_WIFI; then
        echo -e "  ${BLD}Portail captif WiFi :${RST}"
        echo -e "    SSID     : ${YEL}${ap_ssid}${RST}"
        echo -e "    Password : ${YEL}${ap_pass}${RST}"
        echo -e "    IP admin : ${CYN}http://192.168.73.1/${RST}"
        if [[ "$ap_enabled" == "1" ]]; then
            echo -e "    Statut   : ${GRN}ACTIF${RST} (Ethernet absent au moment de l'install)"
        else
            echo -e "    Statut   : Inactif (Ethernet présent) — activable dans Paramètres"
        fi
        echo -e "    Credentials : ${YEL}$THYRA_HOME/wifi_credentials.txt${RST}"
        echo ""
    fi
    echo -e "  ${CYN}sudo reboot${RST}  ← recommandé pour finaliser"
    echo ""
}

# ═════════════════════════════════════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════════════════════════════════════
main() {
    print_banner
    check_root
    check_os
    check_network
    detect_hardware
    install_packages
    create_user
    create_directories
    install_app_code
    setup_python_venv
    init_database
    configure_nginx
    configure_supervisor
    configure_sudo
    configure_openbox
    configure_autologin
    if $IS_RPI; then
        configure_display_rpi
        disable_desktop_session
    fi
    configure_initial_ap
    create_wifi_connect_script
    generate_splash
    install_boot_network_check
    start_services
    verify_installation
    print_summary
}

main "$@"
