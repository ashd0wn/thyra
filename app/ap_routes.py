#!/usr/bin/env python3
# ap_routes.py - routes portail captif, importées dans server.py
# Ce fichier est inclus automatiquement dans le déploiement.
# Les routes sont enregistrées dans server.py via : from ap_routes import register_ap_routes

import subprocess
import logging

log = logging.getLogger("thyra.ap")


def register_ap_routes(app, get_setting, set_setting):
    """Enregistre les routes /api/ap/* dans l'app Flask."""

    @app.route("/api/ap/status")
    def api_ap_status():
        from flask import jsonify
        try:
            result = subprocess.run(
                ["/opt/thyra/scripts/ap_manager.sh", "status"],
                capture_output=True, text=True, timeout=5
            )
            running = result.stdout.strip() == "running"
        except Exception:
            running = False
        ssid = get_setting("ap_ssid", "Thyra")
        return jsonify({"running": running, "ssid": ssid})

    @app.route("/api/ap/toggle", methods=["POST"])
    def api_ap_toggle():
        from flask import jsonify, request, session, abort
        if not session.get("user_id"):
            abort(401)

        data    = request.get_json(silent=True) or {}
        enabled = data.get("enabled", False)
        ssid    = data.get("ssid",    get_setting("ap_ssid",    "Thyra"))
        password= data.get("password",get_setting("ap_password","thyra"))
        channel = data.get("channel", get_setting("ap_channel", "6"))

        set_setting("ap_enabled", "1" if enabled else "0")
        set_setting("ap_ssid",    ssid)
        set_setting("ap_password",password)
        set_setting("ap_channel", str(channel))

        # Envoie signal au processus ap_manager via supervisord
        try:
            if enabled:
                subprocess.Popen(
                    ["sudo", "/opt/thyra/scripts/ap_manager.sh", "start"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
                )
                status = "Portail captif démarré"
            else:
                subprocess.Popen(
                    ["sudo", "/opt/thyra/scripts/ap_manager.sh", "stop"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
                )
                status = "Portail captif arrêté"
        except Exception as e:
            log.error("AP toggle error: %s", e)
            status = f"Erreur: {e}"

        return jsonify({"status": status, "enabled": enabled})
