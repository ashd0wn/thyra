#!/usr/bin/env bash
# =============================================================================
# Thyra — Script de désinstallation complète
# Remet le système dans l'état antérieur à l'installation
# Usage: sudo bash uninstall.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
CYN='\033[0;36m'; BLD='\033[1m';    RST='\033[0m'

log()     { echo -e "${CYN}[$(date '+%H:%M:%S')]${RST} $*"; }
ok()      { echo -e "${GRN}  ✓ $*${RST}"; }
warn()    { echo -e "${YEL}  ⚠ $*${RST}"; }
section() { echo -e "\n${BLD}${CYN}══ $* ══${RST}"; }

THYRA_HOME="/opt/thyra"
THYRA_USER="thyra"

# ── Confirmation ──────────────────────────────────────────────────────────────
echo -e "${RED}${BLD}"
cat <<'EOF'
  _____ _                       
 |_   _| |__  _   _ _ __ __ _  
   | | | '_ \| | | | '__/ _` | 
   | | | | | | |_| | | | (_| | 
   |_| |_| |_|\__, |_|  \__,_| 
              |___/             
   DÉSINSTALLATION COMPLÈTE
EOF
echo -e "${RST}"
echo -e "${YEL}  Ceci va supprimer TOUTES les données Thyra :${RST}"
echo -e "  • /opt/thyra (assets, base de données, code)"
echo -e "  • Utilisateur système 'thyra'"
echo -e "  • Config Nginx, Supervisor, Sudoers"
echo -e "  • Service systemd thyra-netcheck"
echo -e "  • Modifications /boot/config.txt et cmdline.txt"
echo -e "  • Réactivation du display manager (LightDM si présent)"
echo ""
read -rp "  Confirmer la désinstallation ? [oui/NON] : " CONFIRM
if [[ "${CONFIRM,,}" != "oui" ]]; then
    echo "  Annulé."
    exit 0
fi

[[ $EUID -eq 0 ]] || { echo -e "${RED}Exécuter en root : sudo bash uninstall.sh${RST}"; exit 1; }

# ── 1. Arrêt des services Thyra ───────────────────────────────────────────────
section "Arrêt des services"

# Portail captif : on coupe proprement avant tout
if [[ -x "$THYRA_HOME/scripts/ap_manager.sh" ]]; then
    bash "$THYRA_HOME/scripts/ap_manager.sh" stop 2>/dev/null || true
    ok "Portail captif arrêté"
fi

# Processus supervisor Thyra
if command -v supervisorctl &>/dev/null; then
    supervisorctl stop thyra-server thyra-viewer thyra-x11 \
        thyra-watchdog thyra-ap 2>/dev/null || true
    ok "Processus Thyra arrêtés"
fi

# Service netcheck
if systemctl is-active thyra-netcheck &>/dev/null 2>&1; then
    systemctl stop thyra-netcheck 2>/dev/null || true
fi
if systemctl is-enabled thyra-netcheck &>/dev/null 2>&1; then
    systemctl disable thyra-netcheck 2>/dev/null || true
fi
rm -f /etc/systemd/system/thyra-netcheck.service
systemctl daemon-reload 2>/dev/null || true
ok "Service thyra-netcheck supprimé"

# ── 2. Supervisor ─────────────────────────────────────────────────────────────
section "Suppression config Supervisor"

rm -f /etc/supervisor/conf.d/thyra.conf
if command -v supervisorctl &>/dev/null; then
    supervisorctl reread  2>/dev/null || true
    supervisorctl update  2>/dev/null || true
fi
ok "Config supervisor supprimée"

# ── 3. Nginx ──────────────────────────────────────────────────────────────────
section "Suppression config Nginx"

rm -f /etc/nginx/sites-enabled/thyra
rm -f /etc/nginx/sites-available/thyra

# Réactiver le site default si la conf existe
if [[ -f /etc/nginx/sites-available/default ]]; then
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    ok "Site Nginx default réactivé"
fi

if nginx -t &>/dev/null 2>&1; then
    systemctl reload nginx 2>/dev/null || true
    ok "Nginx rechargé"
else
    warn "Config Nginx invalide après nettoyage — vérifiez manuellement"
fi

# ── 4. Sudoers ────────────────────────────────────────────────────────────────
section "Suppression règles sudo"

rm -f /etc/sudoers.d/thyra
ok "Règles sudo supprimées"

# ── 5. Autologin tty1 ─────────────────────────────────────────────────────────
section "Suppression autologin tty1"

if [[ -f /etc/systemd/system/getty@tty1.service.d/autologin.conf ]]; then
    rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
    rmdir --ignore-fail-on-non-empty \
        /etc/systemd/system/getty@tty1.service.d 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    ok "Autologin tty1 supprimé"
else
    ok "Pas d'autologin configuré"
fi

# ── 6. Xwrapper ──────────────────────────────────────────────────────────────
section "Restauration Xwrapper.config"

if [[ -f /etc/X11/Xwrapper.config ]]; then
    sed -i 's/^allowed_users=anybody/allowed_users=console/' \
        /etc/X11/Xwrapper.config 2>/dev/null || true
    sed -i '/^needs_root_rights=yes/d' \
        /etc/X11/Xwrapper.config 2>/dev/null || true
    ok "Xwrapper restauré (allowed_users=console)"
fi

# ── 7. Display manager ────────────────────────────────────────────────────────
section "Restauration du display manager"

# Remet graphical.target si on était en multi-user
CURRENT_TARGET=$(systemctl get-default 2>/dev/null || echo "")
if [[ "$CURRENT_TARGET" == "multi-user.target" ]]; then
    # Vérifie si un DM est installé
    if systemctl cat lightdm &>/dev/null 2>&1; then
        systemctl set-default graphical.target 2>/dev/null || true
        systemctl enable lightdm 2>/dev/null || true
        ok "LightDM réactivé — target graphical.target"
    elif systemctl cat gdm3 &>/dev/null 2>&1; then
        systemctl set-default graphical.target 2>/dev/null || true
        systemctl enable gdm3 2>/dev/null || true
        ok "GDM3 réactivé — target graphical.target"
    else
        warn "Aucun display manager trouvé — target laissé en multi-user"
    fi
else
    ok "Target système inchangé ($CURRENT_TARGET)"
fi

# ── 8. /boot/config.txt ───────────────────────────────────────────────────────
section "Nettoyage /boot/config.txt"

CONFIG_TXT=""
[[ -f /boot/firmware/config.txt ]] && CONFIG_TXT="/boot/firmware/config.txt"
[[ -f /boot/config.txt ]] && CONFIG_TXT="/boot/config.txt"

if [[ -n "$CONFIG_TXT" ]]; then
    # Supprime les lignes ajoutées par Thyra
    sed -i '/^hdmi_force_hotplug=1/d'   "$CONFIG_TXT" 2>/dev/null || true
    sed -i '/^hdmi_group=2/d'           "$CONFIG_TXT" 2>/dev/null || true
    sed -i '/^hdmi_mode=82/d'           "$CONFIG_TXT" 2>/dev/null || true
    sed -i '/^disable_overscan=1/d'     "$CONFIG_TXT" 2>/dev/null || true
    sed -i '/^gpu_mem=/d'               "$CONFIG_TXT" 2>/dev/null || true
    sed -i '/^dtparam=cma-size=/d'      "$CONFIG_TXT" 2>/dev/null || true
    sed -i '/^# Thyra:/d'               "$CONFIG_TXT" 2>/dev/null || true
    ok "config.txt nettoyé ($CONFIG_TXT)"
else
    ok "Pas de config.txt trouvé (plateforme PC)"
fi

# /boot/cmdline.txt
CMDLINE=""
[[ -f /boot/firmware/cmdline.txt ]] && CMDLINE="/boot/firmware/cmdline.txt"
[[ -f /boot/cmdline.txt ]] && CMDLINE="/boot/cmdline.txt"

if [[ -n "$CMDLINE" ]]; then
    sed -i 's/ consoleblank=0//g' "$CMDLINE" 2>/dev/null || true
    ok "cmdline.txt nettoyé ($CMDLINE)"
fi

# ── 9. raspi-config — restauration blanking ────────────────────────────────────
section "Restauration raspi-config"

if command -v raspi-config &>/dev/null; then
    raspi-config nonint do_blanking 0 2>/dev/null \
        && ok "Blanking réactivé (raspi-config)" || true
    # Restaure boot en desktop autologin si LightDM présent
    if systemctl cat lightdm &>/dev/null 2>&1; then
        raspi-config nonint do_boot_behaviour B4 2>/dev/null \
            && ok "raspi-config : boot desktop autologin restauré" || true
    fi
fi

# ── 10. iptables — nettoyage règles portail captif ─────────────────────────────
section "Nettoyage iptables"

iptables -t nat -F 2>/dev/null || true
iptables -F FORWARD 2>/dev/null || true
ok "Règles iptables vidées"

# ── 11. Fichiers résiduels ────────────────────────────────────────────────────
section "Suppression fichiers résiduels"

# Config hostapd Thyra
rm -f /etc/hostapd/thyra-hostapd.conf
# Config dnsmasq Thyra  
rm -f /etc/dnsmasq.d/thyra.conf
# Logs Nginx Thyra
rm -f /var/log/nginx/thyra_access.log
rm -f /var/log/nginx/thyra_error.log
ok "Fichiers de config résiduels supprimés"

# ── 12. Logs Thyra ────────────────────────────────────────────────────────────
section "Suppression des logs"

rm -rf /var/log/thyra
ok "Répertoire /var/log/thyra supprimé"

# ── 13. Utilisateur système ───────────────────────────────────────────────────
section "Suppression utilisateur système"

if id "$THYRA_USER" &>/dev/null; then
    # Tue tous les processus de cet utilisateur avant suppression
    pkill -u "$THYRA_USER" 2>/dev/null || true
    sleep 1
    userdel -r "$THYRA_USER" 2>/dev/null || userdel "$THYRA_USER" 2>/dev/null || true
    ok "Utilisateur $THYRA_USER supprimé"
else
    ok "Utilisateur $THYRA_USER déjà absent"
fi

# Home résiduel
rm -rf "/home/$THYRA_USER"

# ── 14. Répertoire principal ──────────────────────────────────────────────────
section "Suppression de $THYRA_HOME"

if [[ -d "$THYRA_HOME" ]]; then
    rm -rf "$THYRA_HOME"
    ok "$THYRA_HOME supprimé"
else
    ok "$THYRA_HOME déjà absent"
fi

# ── 15. Résumé ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GRN}${BLD}╔══════════════════════════════════════════════════════════╗${RST}"
echo -e "${GRN}${BLD}║         Thyra désinstallé proprement.                   ║${RST}"
echo -e "${GRN}${BLD}╚══════════════════════════════════════════════════════════╝${RST}"
echo ""
echo -e "  Ce qui a été ${GRN}supprimé${RST} :"
echo -e "  • /opt/thyra (code, assets, base de données)"
echo -e "  • /home/thyra, utilisateur système 'thyra'"
echo -e "  • Config Nginx, Supervisor, Sudoers, Systemd"
echo -e "  • Modifications boot (config.txt, cmdline.txt)"
echo -e "  • Logs, iptables, hostapd/dnsmasq Thyra"
echo ""
echo -e "  Ce qui a été ${YEL}restauré${RST} :"
echo -e "  • Display manager (LightDM/GDM si présent)"
echo -e "  • Xwrapper.config → allowed_users=console"
echo -e "  • Blanking écran (raspi-config)"
echo ""
echo -e "  ${BLD}Redémarrage recommandé :${RST} ${CYN}sudo reboot${RST}"
echo ""
