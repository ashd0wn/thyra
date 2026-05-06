#!/usr/bin/env bash
# /opt/thyra/scripts/ap_manager.sh
# Gestion du portail captif WiFi — hostapd + dnsmasq + iptables
# Usage: ap_manager.sh {start|stop|status|run}

set -euo pipefail

CONF_DB="/opt/thyra/db/thyra.db"
HOSTAPD_CONF="/etc/hostapd/thyra-hostapd.conf"
DNSMASQ_CONF="/etc/dnsmasq.d/thyra.conf"
IFACE_AP="wlan0"
IFACE_ETH="eth0"
AP_IP="192.168.73.1"
AP_DHCP_START="192.168.73.10"
AP_DHCP_END="192.168.73.100"
AP_DHCP_LEASE="2h"
LOGFILE="/var/log/thyra/ap.log"

log() { echo "[AP $(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE"; }

# ── Lecture des paramètres depuis la base SQLite ───────────────────────────
read_setting() {
    sqlite3 "$CONF_DB" "SELECT value FROM settings WHERE key='$1';" 2>/dev/null || echo ""
}

# ── Génération des configs ─────────────────────────────────────────────────
write_hostapd_conf() {
    local ssid pass channel
    ssid=$(read_setting ap_ssid); ssid=${ssid:-Thyra}
    pass=$(read_setting ap_password)
    channel=$(read_setting ap_channel); channel=${channel:-6}

    log "SSID='$ssid' channel=$channel"

    cat > "$HOSTAPD_CONF" <<HCONF
interface=${IFACE_AP}
driver=nl80211
ssid=${ssid}
hw_mode=g
channel=${channel}
wmm_enabled=0
macaddr_acl=0
ignore_broadcast_ssid=0
# Sécurité
$(if [[ -n "$pass" && ${#pass} -ge 8 ]]; then
cat <<WPA
auth_algs=1
wpa=2
wpa_passphrase=${pass}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP
WPA
fi)
# Portail captif
# Le navigateur sera redirigé vers l'interface Thyra
HCONF
}

write_dnsmasq_conf() {
    cat > "$DNSMASQ_CONF" <<DCONF
# Thyra captive portal - dnsmasq
interface=${IFACE_AP}
bind-interfaces
dhcp-range=${AP_DHCP_START},${AP_DHCP_END},${AP_DHCP_LEASE}
dhcp-option=option:router,${AP_IP}
dhcp-option=option:dns-server,${AP_IP}
# Hijack ALL DNS → portail captif
address=/#/${AP_IP}
# RFC 8910 : DHCP captive-portal option
# (accélère la détection sur iOS 14+, Android 11+)
dhcp-option=114,http://${AP_IP}/
DCONF
}

# ── Start ──────────────────────────────────────────────────────────────────
start_ap() {
    log "Démarrage du portail captif…"

    # Vérifications
    if ! command -v hostapd &>/dev/null; then
        log "ERREUR: hostapd non installé. Lancez: apt install hostapd"
        exit 1
    fi
    if ! command -v dnsmasq &>/dev/null; then
        log "ERREUR: dnsmasq non installé. Lancez: apt install dnsmasq"
        exit 1
    fi

    # Arrêt des services réseau existants sur wlan0
    log "Arrêt de wpa_supplicant sur ${IFACE_AP}…"
    pkill -f "wpa_supplicant.*${IFACE_AP}" 2>/dev/null || true
    systemctl stop wpa_supplicant@${IFACE_AP} 2>/dev/null || true
    nmcli device disconnect "$IFACE_AP" 2>/dev/null || true

    # IP statique sur l'interface AP
    log "Configuration IP ${AP_IP} sur ${IFACE_AP}…"
    ip link set "$IFACE_AP" up
    ip addr flush dev "$IFACE_AP"
    ip addr add "${AP_IP}/24" dev "$IFACE_AP"

    # Génération des configs
    write_hostapd_conf
    write_dnsmasq_conf

    # Arrêt propre du dnsmasq système (il sera relancé par hostapd ou séparément)
    systemctl stop dnsmasq 2>/dev/null || true

    # Démarrage hostapd
    log "Démarrage de hostapd…"
    hostapd -B -P /run/thyra-hostapd.pid "$HOSTAPD_CONF" 2>>"$LOGFILE"
    sleep 1

    # Démarrage dnsmasq
    log "Démarrage de dnsmasq…"
    dnsmasq --conf-file="$DNSMASQ_CONF" --pid-file=/run/thyra-dnsmasq.pid 2>>"$LOGFILE"

    # ── iptables : portail captif ─────────────────────────────────────────
    log "Configuration iptables…"
    # Activer le forwarding
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    # Flush les règles existantes sur cette interface
    iptables -t nat   -F PREROUTING  2>/dev/null || true
    iptables -t nat   -F POSTROUTING 2>/dev/null || true
    iptables         -F FORWARD      2>/dev/null || true

    # Redirection HTTP → portail (port 80 Thyra)
    iptables -t nat -A PREROUTING -i "$IFACE_AP" -p tcp --dport 80  \
             -j DNAT --to-destination "${AP_IP}:80"
    iptables -t nat -A PREROUTING -i "$IFACE_AP" -p tcp --dport 443 \
             -j DNAT --to-destination "${AP_IP}:80"
    # DNS
    iptables -t nat -A PREROUTING -i "$IFACE_AP" -p udp --dport 53  \
             -j DNAT --to-destination "${AP_IP}:53"

    # NAT sortant si ethernet disponible (optionnel : partage internet)
    if ip link show "$IFACE_ETH" &>/dev/null; then
        iptables -t nat -A POSTROUTING -o "$IFACE_ETH" -j MASQUERADE
        iptables -A FORWARD -i "$IFACE_AP" -o "$IFACE_ETH" -j ACCEPT
        iptables -A FORWARD -i "$IFACE_ETH" -o "$IFACE_AP" -m state \
                 --state RELATED,ESTABLISHED -j ACCEPT
    fi

    log "Portail captif actif — SSID: $(read_setting ap_ssid) — IP: ${AP_IP}"
}

# ── Stop ───────────────────────────────────────────────────────────────────
stop_ap() {
    log "Arrêt du portail captif…"

    # Kill hostapd/dnsmasq Thyra
    [[ -f /run/thyra-hostapd.pid  ]] && kill "$(cat /run/thyra-hostapd.pid)"  2>/dev/null || true
    [[ -f /run/thyra-dnsmasq.pid  ]] && kill "$(cat /run/thyra-dnsmasq.pid)"  2>/dev/null || true
    pkill -f "hostapd.*thyra" 2>/dev/null || true

    # Nettoyage iptables
    iptables -t nat -F 2>/dev/null || true
    iptables        -F FORWARD 2>/dev/null || true

    # Libération IP
    ip addr flush dev "$IFACE_AP" 2>/dev/null || true

    # Remettre NetworkManager en contrôle
    nmcli device connect "$IFACE_AP" 2>/dev/null || true

    log "Portail captif arrêté."
}

# ── Status ──────────────────────────────────────────────────────────────────
status_ap() {
    if pgrep -f "hostapd.*thyra" &>/dev/null; then
        echo "running"
    else
        echo "stopped"
    fi
}

# ── Run (boucle supervisord) ───────────────────────────────────────────────
run_ap() {
    # Vérifie les settings et démarre/arrête selon ap_enabled
    while true; do
        local enabled
        enabled=$(read_setting ap_enabled)
        if [[ "$enabled" == "1" ]]; then
            if ! pgrep -f "hostapd.*thyra" &>/dev/null; then
                start_ap
            fi
        else
            if pgrep -f "hostapd.*thyra" &>/dev/null; then
                stop_ap
            fi
        fi
        sleep 15
    done
}

# ── Entrée ──────────────────────────────────────────────────────────────────
case "${1:-}" in
    start)  start_ap  ;;
    stop)   stop_ap   ;;
    status) status_ap ;;
    run)    run_ap    ;;
    *)
        echo "Usage: $0 {start|stop|status|run}"
        exit 1
        ;;
esac
