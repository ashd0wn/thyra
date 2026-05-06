#!/usr/bin/env bash
# wifi_connect.sh — Connecte le Pi à un réseau WiFi existant
# Usage: sudo wifi_connect.sh <ssid> <password>
set -euo pipefail

SSID="${1:-}"
PASS="${2:-}"
[[ -z "$SSID" ]] && { echo "error:ssid_required"; exit 1; }

# Arrêt portail captif
/opt/thyra/scripts/ap_manager.sh stop 2>/dev/null || true
sleep 2

# Libère wlan0
ip addr flush dev wlan0 2>/dev/null || true
ip link set wlan0 down  2>/dev/null || true
sleep 1
ip link set wlan0 up    2>/dev/null || true
sleep 2

if command -v nmcli &>/dev/null; then
    nmcli connection delete "$SSID" 2>/dev/null || true

    if [[ -n "$PASS" ]]; then
        nmcli device wifi connect "$SSID" password "$PASS" ifname wlan0 2>&1 || {
            echo "error:nmcli_failed"; exit 1
        }
    else
        nmcli device wifi connect "$SSID" ifname wlan0 2>&1 || {
            echo "error:nmcli_failed"; exit 1
        }
    fi

    sleep 5
    IP=$(nmcli -g IP4.ADDRESS device show wlan0 2>/dev/null \
         | head -1 | cut -d/ -f1 || echo "")
    [[ -z "$IP" ]] && { echo "error:no_ip_obtained"; exit 1; }
    echo "connected:${IP}"

elif command -v wpa_cli &>/dev/null; then
    wpa_passphrase "$SSID" "$PASS" >> /etc/wpa_supplicant/wpa_supplicant.conf
    wpa_cli -i wlan0 reconfigure 2>/dev/null
    sleep 8
    IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}' \
         || hostname -I | awk '{print $1}')
    [[ -z "$IP" ]] && { echo "error:no_ip_obtained"; exit 1; }
    echo "connected:${IP}"
else
    echo "error:no_wifi_manager"; exit 1
fi
