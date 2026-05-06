#!/usr/bin/env bash
# /opt/thyra/scripts/watchdog.sh
# Empêche l'écran de s'éteindre et vérifie que le viewer tourne

set -euo pipefail

export DISPLAY=":0"
LOGFILE="/var/log/thyra/watchdog.log"
VIEWER_API="http://127.0.0.1:5000/api/settings"
CHECK_INTERVAL=30

log() { echo "[WD $(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE"; }

# ── Désactivation économiseurs d'écran / DPMS ──────────────────────────────
disable_screensaver() {
    # X11
    if [[ -n "${DISPLAY:-}" ]]; then
        xset s off       2>/dev/null || true
        xset s noblank   2>/dev/null || true
        xset -dpms       2>/dev/null || true
        xset dpms 0 0 0  2>/dev/null || true
    fi

    # Framebuffer
    echo -e "\033[9;0]" > /dev/tty1 2>/dev/null || true

    # RPi consoleblank
    if [[ -f /sys/module/kernel/parameters/consoleblank ]]; then
        echo 0 > /sys/module/kernel/parameters/consoleblank 2>/dev/null || true
    fi
}

# ── Rotation d'écran selon settings ───────────────────────────────────────
apply_rotation() {
    local rotate
    rotate=$(sqlite3 /opt/thyra/db/thyra.db \
             "SELECT value FROM settings WHERE key='display_rotate';" 2>/dev/null || echo "0")

    case "$rotate" in
        1) XRANDR_ROT="right";;
        2) XRANDR_ROT="inverted";;
        3) XRANDR_ROT="left";;
        *) XRANDR_ROT="normal";;
    esac

    xrandr --output HDMI-1 --rotate "$XRANDR_ROT" 2>/dev/null || \
    xrandr --output HDMI-2 --rotate "$XRANDR_ROT" 2>/dev/null || \
    xrandr --auto 2>/dev/null || true

    # Framebuffer rotate pour fbi / vlc
    # (nécessite /boot/config.txt display_rotate — fait par l'installer)
}

# ── Vérification de l'API ──────────────────────────────────────────────────
check_server() {
    if curl -sf --max-time 3 "$VIEWER_API" >/dev/null 2>&1; then
        return 0
    fi
    log "WARN: Serveur Thyra non disponible — relance supervisord"
    supervisorctl restart thyra-server 2>/dev/null || true
    return 1
}

# ── Boucle principale ──────────────────────────────────────────────────────
log "Watchdog démarré."

ROTATION_APPLIED=0

while true; do
    disable_screensaver

    if [[ $ROTATION_APPLIED -eq 0 ]]; then
        apply_rotation
        ROTATION_APPLIED=1
    fi

    check_server || true

    sleep "$CHECK_INTERVAL"
done
