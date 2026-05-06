#!/usr/bin/env bash
# boot_network_check.sh — Active le portail captif si pas de réseau au boot
sleep 10

ETH_UP=false
WIFI_UP=false

ip route | grep -q "^default.*eth0" && ETH_UP=true
ip addr show wlan0 2>/dev/null | grep -q "inet " && WIFI_UP=true

if ! $ETH_UP && ! $WIFI_UP; then
    sqlite3 /opt/thyra/db/thyra.db \
        "UPDATE settings SET value='1' WHERE key='ap_enabled';" 2>/dev/null || true
    supervisorctl start thyra-ap 2>/dev/null || true
fi
