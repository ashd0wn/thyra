<div align="center">

<!-- Logo ASCII-art fallback si SVG non rendu -->
<img src="static/img/logo.svg" alt="Thyra Logo" width="96" height="96">

# Thyra

**θύρα · Digital Signage bare-metal pour Raspberry Pi et PC**

[![License: MIT](https://img.shields.io/badge/License-MIT-6366f1.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Raspberry%20Pi%20%7C%20Debian%20%7C%20Ubuntu-818cf8.svg)](#compatibilité)
[![Python](https://img.shields.io/badge/Python-3.9%2B-blue.svg)](https://python.org)
[![Stack](https://img.shields.io/badge/Stack-Flask%20%2B%20Nginx%20%2B%20Supervisor-informational.svg)](#architecture)

*Thyra (θύρα) — « la porte, l'ouverture » en grec ancien.*  
*Une fenêtre ouverte sur un monde, posée dans votre espace.*

---

[Démo](#aperçu) · [Installation](#installation-en-une-commande) · [Fonctionnalités](#fonctionnalités) · [Architecture](#architecture) · [FAQ](#faq)

</div>

---

## Pourquoi Thyra ?

[Anthias](https://github.com/Screenly/Anthias) (ex-Screenly OSE) est l'alternative open source de référence au signage commercial — mais sa dockerisation en 2022 l'a rendu **trop lourd pour un Raspberry Pi 3** (1 Go de RAM), et son mode sans-fil nécessite toujours un câble Ethernet pour la configuration initiale.

**Thyra** reprend l'esprit de l'ancienne version bare-metal de Screenly OSE (2021) :

| | Anthias (actuel) | **Thyra** |
|---|---|---|
| Déploiement | Docker Compose | Bare-metal natif |
| RAM minimale | ~700 MB | ~180 MB |
| Portail captif WiFi | ✗ | ✓ |
| Raspberry Pi 3 | ⚠ Difficile | ✓ |
| PC Debian/Ubuntu x86_64 | ✗ | ✓ |
| Installation | Multi-étapes | Une commande |
| Interface | Angular | Vanilla JS, thème sombre |

---

## Aperçu

```
┌─────────────────────────────────────────────────────┐
│  Thyra — Interface web                              │
│                                                     │
│  ┌──────────┐  ┌───────────────────────────────┐   │
│  │ Médias   │  │  Médiathèque         [+ Ajouter│   │
│  │ Planning │  │  ┌──────┐ ┌──────┐ ┌──────┐  │   │
│  │ Paramèt. │  │  │ IMG  │ │ VID  │ │ WEB  │  │   │
│  │          │  │  │      │ │      │ │      │  │   │
│  └──────────┘  │  └──────┘ └──────┘ └──────┘  │   │
│                └───────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

L'interface est accessible depuis n'importe quel navigateur sur le réseau local (`http://<ip-du-pi>/`). Le viewer tourne en parallèle sur l'écran HDMI branché au Pi ou au PC.

---

## Fonctionnalités

### Lecture de médias
- **Images** — JPEG, PNG, GIF, WebP, BMP  
  → `fbi` (framebuffer, sans X11) sur Raspberry Pi  
  → `feh` (X11) sur PC Debian/Ubuntu
- **Vidéos** — MP4, WebM, MKV, AVI, MOV  
  → VLC avec sortie `xvideo` (X11) ou `fb` (framebuffer) selon l'environnement
- **Pages web** — URL complète affichée en kiosk Chromium  
  → Détection automatique du binaire (`chromium-browser` / `chromium`)
- **Durée personnalisable** par asset (1 s → 1 h)
- **Lecture aléatoire** optionnelle

### Planning de diffusion
- Règles par **plages horaires** (début/fin)
- Filtres par **jours de la semaine** (sélection individuelle L-M-M-J-V-S-D)
- **Dates de validité** optionnelles (campagne du 1er au 31 décembre)
- **Priorités** numériques (plus grand = prioritaire)
- Sans règle = diffusion permanente 24h/24

### Portail captif WiFi *(fonctionnalité exclusive)*
- Transforme le Pi en **point d'accès WiFi autonome** via `hostapd` + `dnsmasq`
- Tout navigateur connecté au réseau WiFi `Thyra` est redirigé vers l'interface d'administration
- Configuration depuis l'interface : SSID, mot de passe (WPA2 ou réseau ouvert), canal
- Compatible RFC 8910 (détection automatique du portail sur iOS 14+, Android 11+)
- **Zéro câble Ethernet requis** après installation

### Interface d'administration
- Thème sombre moderne, responsive (mobile/tablette/desktop)
- Gestion des médias : upload par glisser-déposer, ajout d'URL, prévisualisation
- Gestion des utilisateurs avec **3 rôles** :
  - `admin` — accès complet, paramètres, gestion utilisateurs
  - `editor` — gestion des médias et du planning
  - `viewer` — consultation seule
- Authentification activable/désactivable (réseau local de confiance)
- Rechargement du viewer à chaud sans redémarrage
- Bouton de redémarrage système

### Système
- **Watchdog** intégré : surveille les processus, empêche l'extinction de l'écran
- **Rotation d'affichage** : 0°/90°/180°/270° (utile pour les écrans portrait)
- **Économiseurs d'écran désactivés** automatiquement (DPMS, consoleblank, xset)
- Logs rotatifs dans `/var/log/thyra/`
- API REST interne utilisée par le viewer (rechargeable à chaud)

---

## Architecture

```
                        ┌─────────────────────────────────┐
                        │         Raspberry Pi / PC        │
                        │                                  │
  Navigateur  ──HTTP──▶ │  Nginx (port 80)                 │
                        │    │                             │
                        │    ├─ /static/*   ──▶ fichiers   │
                        │    ├─ /assets_files/* ──▶ médias │
                        │    └─ /* ──proxy──▶ Gunicorn :5000│
                        │                    │             │
                        │              Flask (server.py)   │
                        │                    │             │
                        │               SQLite DB          │
                        │                    │             │
                        │         reload.flag (IPC)        │
                        │                    │             │
                        │            viewer.py             │
                        │      ┌──────┬──────┬──────┐      │
                        │      │ fbi/ │ VLC  │Chrom.│      │
                        │      │ feh  │      │kiosk │      │
                        │      └──────┴──────┴──────┘      │
                        │             HDMI                  │
                        └─────────────────────────────────┘
                        
  Supervisord gère : thyra-server · thyra-viewer
                     thyra-x11    · thyra-watchdog
                     thyra-ap (portail captif, optionnel)
```

### Stack technique

| Composant | Choix | Justification |
|---|---|---|
| Backend | Python 3 + Flask + Gunicorn | Légèreté, même lignée que l'OSE original |
| Base de données | SQLite | Zéro overhead RAM, suffisant pour du signage local |
| Serveur web | Nginx | Serving statique natif, bien plus léger qu'Apache sur Pi |
| Processus | Supervisord | Remplacement direct de Docker Compose, bare-metal |
| Images | fbi (Pi) / feh (PC) | fbi = framebuffer natif, pas de X11 requis sur Pi |
| Vidéo | VLC | Universel, supporte framebuffer et X11 |
| Pages web | Chromium kiosk | Seul navigateur fiable en mode kiosk embarqué |
| WiFi AP | hostapd + dnsmasq | Standard de facto, bien documenté |

---

## Compatibilité

| Plateforme | Statut | Notes |
|---|---|---|
| Raspberry Pi 3B / 3B+ | ✅ Principal | Raspberry Pi OS Bullseye/Bookworm (32 et 64 bit) |
| Raspberry Pi 4 / 400 | ✅ | Toutes versions Pi OS |
| Raspberry Pi 5 | ✅ | Pi OS Bookworm recommandé |
| Raspberry Pi Zero 2 W | ⚠ | Fonctionnel, performances limitées |
| PC Debian 11 (Bullseye) | ✅ | x86_64 |
| PC Debian 12 (Bookworm) | ✅ | x86_64, recommandé |
| Ubuntu 22.04 LTS | ✅ | x86_64 |
| Ubuntu 24.04 LTS | ✅ | x86_64 |
| Ubuntu Server (sans GUI) | ✅ | X11 minimal installé par le script |
| armhf / arm64 | ✅ | Détection automatique |

---

## Installation en une commande

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/ashd0wn/thyra/main/deploy.sh)
```

> **Prérequis** : Debian/Raspberry Pi OS/Ubuntu fraîchement installé, connexion internet, accès root.

Le script effectue dans l'ordre :
1. Détection de la plateforme (Pi vs PC, architecture, RAM, WiFi)
2. Installation des paquets système (APT)
3. Création de l'utilisateur système `thyra`
4. Clonage du dépôt dans `/opt/thyra/`
5. Création du virtualenv Python et installation des dépendances
6. Initialisation de la base SQLite (compte admin/admin créé)
7. Configuration Nginx (reverse proxy + serving statique)
8. Configuration Supervisord (5 processus gérés)
9. Configuration des règles sudo (portail captif)
10. Désactivation des économiseurs d'écran
11. Vérification finale de l'API
12. Affichage du récapitulatif avec l'URL d'accès

Durée typique : **8 à 15 minutes** selon la connexion et la plateforme.

### Première connexion

```
URL : http://<adresse-ip>/
Login : admin
Mot de passe : admin   ← À changer immédiatement dans Paramètres → Utilisateurs
```

### Installation locale (développement / CI)

```bash
git clone https://github.com/ashd0wn/thyra.git
cd thyra
sudo bash deploy.sh
```

Si `app/server.py` est détecté dans le répertoire courant, le script copie depuis les sources locales au lieu de cloner depuis GitHub.

---

## Utilisation

### Ajouter un média

1. Aller dans **Médias** → **Ajouter un média**
2. Choisir l'onglet :
   - **Fichier local** : glisser-déposer ou parcourir (images, vidéos, HTML)
   - **URL distante** : lien direct vers une image ou vidéo en ligne
   - **Page Web** : URL d'un site à afficher en kiosk
3. Définir le nom et la durée d'affichage
4. Cliquer **Ajouter** → le viewer recharge automatiquement

### Planifier un média

Sans règle de planning, tous les médias actifs tournent en boucle 24h/24.

Pour affiner :
1. Aller dans **Planning** → **Nouvelle règle**
2. Sélectionner le média concerné
3. Définir les jours, les heures, les dates optionnelles et la priorité
4. **Créer la règle**

Exemple : afficher une vidéo promotionnelle uniquement du lundi au vendredi, de 9h à 18h, du 1er au 31 décembre.

### Activer le portail captif WiFi

1. Aller dans **Paramètres** → section **Portail captif WiFi**
2. Activer, renseigner le SSID et le mot de passe
3. **Enregistrer** puis **Appliquer maintenant**

Le Pi devient un point d'accès WiFi. Tout appareil connecté à ce réseau et ouvrant un navigateur est redirigé vers l'interface Thyra.

---

## Commandes utiles

```bash
# État de tous les processus
supervisorctl status

# Logs en direct
tail -f /var/log/thyra/*.log

# Redémarrer uniquement le viewer (sans couper le serveur)
supervisorctl restart thyra-viewer

# Redémarrer tout Thyra
supervisorctl restart all

# Arrêter complètement
supervisorctl stop all

# Portail captif manuellement
sudo /opt/thyra/scripts/ap_manager.sh start
sudo /opt/thyra/scripts/ap_manager.sh stop
sudo /opt/thyra/scripts/ap_manager.sh status

# Base de données (inspection directe)
sqlite3 /opt/thyra/db/thyra.db ".tables"
sqlite3 /opt/thyra/db/thyra.db "SELECT name, asset_type, is_active FROM assets;"
```

---

## Structure du dépôt

```
thyra/
├── deploy.sh                  # Script d'installation unique
├── app/
│   ├── server.py              # Backend Flask (API REST + UI)
│   ├── viewer.py              # Processus d'affichage (images/vidéos/web)
│   └── ap_routes.py           # Routes API portail captif WiFi
├── templates/
│   ├── base.html              # Layout principal (sidebar, nav)
│   ├── login.html             # Page de connexion
│   ├── assets.html            # Gestion des médias
│   ├── schedule.html          # Planning de diffusion
│   └── settings.html          # Paramètres système + utilisateurs
├── static/
│   ├── css/app.css            # Thème sombre complet
│   ├── js/
│   │   ├── app.js             # Utilitaires partagés (API client, toasts)
│   │   ├── assets.js          # Logique page médias
│   │   ├── schedule.js        # Logique page planning
│   │   └── settings.js        # Logique page paramètres
│   └── img/
│       ├── logo.svg           # Logo Thyra (θύρα grecque)
│       └── splash.png         # Écran de démarrage (généré à l'install)
├── nginx/
│   └── thyra.conf             # Config Nginx (reverse proxy + static)
├── services/
│   └── thyra.conf             # Config Supervisord (5 processus)
└── scripts/
    ├── ap_manager.sh          # Gestionnaire portail captif WiFi
    └── watchdog.sh            # Garde-écran + surveillance processus
```

---

## API REST

L'interface web communique avec le backend via une API REST. Elle peut aussi être utilisée directement pour des intégrations.

| Méthode | Endpoint | Description |
|---|---|---|
| `GET` | `/api/assets` | Liste tous les médias |
| `POST` | `/api/assets` | Ajoute un média (multipart ou JSON) |
| `PUT` | `/api/assets/<id>` | Modifie un média |
| `DELETE` | `/api/assets/<id>` | Supprime un média |
| `GET` | `/api/playlist` | Playlist active en ce moment (utilisée par le viewer) |
| `GET` | `/api/schedule` | Liste toutes les règles de planning |
| `POST` | `/api/schedule` | Crée une règle |
| `DELETE` | `/api/schedule/<id>` | Supprime une règle |
| `GET` | `/api/settings` | Paramètres publics |
| `GET` | `/api/ap/status` | Statut du portail captif |
| `POST` | `/api/ap/toggle` | Active/désactive le portail captif |
| `POST` | `/api/system/reboot` | Redémarre le système |
| `POST` | `/api/system/reload_viewer` | Recharge le viewer |

---

## Configuration avancée

### Variables d'environnement

| Variable | Défaut | Description |
|---|---|---|
| `THYRA_HOME` | `/opt/thyra` | Répertoire de base |
| `THYRA_SECRET` | (généré) | Clé secrète Flask (sessions) |
| `THYRA_MAX_MB` | `512` | Taille max d'upload en Mo |
| `THYRA_USER` | `thyra` | Utilisateur système |

### Changer le port d'écoute

Modifier `/etc/nginx/sites-available/thyra.conf` :
```nginx
listen 8080 default_server;
```
Puis `systemctl restart nginx`.

### Stockage des assets uploadés

Les médias sont stockés dans `/opt/thyra/assets/<uuid>/`. Pour pointer vers un stockage externe (NAS, clé USB) :

```bash
mkdir -p /mnt/monnas/thyra-assets
mount /dev/sda1 /mnt/monnas
ln -s /mnt/monnas/thyra-assets /opt/thyra/assets
```

### Désactiver l'authentification (réseau local sûr)

Dans **Paramètres** → **Authentification** → Désactivée.  
Ou directement en base :
```bash
sqlite3 /opt/thyra/db/thyra.db "UPDATE settings SET value='0' WHERE key='auth_enabled';"
supervisorctl restart thyra-server
```

---

## FAQ

**Q : Le viewer ne démarre pas.**  
R : Vérifier que l'écran HDMI est branché *avant* le démarrage. Consulter `/var/log/thyra/viewer_stderr.log`. Si X11 manque : `supervisorctl status thyra-x11`.

**Q : Chromium refuse de démarrer en kiosk.**  
R : Supprimer le profil Chromium corrompu : `rm -rf /home/thyra/.config/chromium/Singleton*` puis `supervisorctl restart thyra-viewer`.

**Q : Le portail captif WiFi ne redirige pas.**  
R : Vérifier qu'`hostapd` et `dnsmasq` sont installés (`apt install hostapd dnsmasq`). Consulter `/var/log/thyra/ap.log`.

**Q : Puis-je gérer plusieurs écrans ?**  
R : Thyra est conçu pour une instance = un écran. Pour plusieurs écrans, déployer une instance par Pi et gérer depuis chaque interface. Une future version pourrait centraliser cela.

**Q : Comment sauvegarder ma configuration ?**  
R : La totalité de la configuration est dans un seul fichier :
```bash
cp /opt/thyra/db/thyra.db ~/thyra_backup_$(date +%Y%m%d).db
```

**Q : Mise à jour depuis GitHub ?**  
```bash
cd /tmp && git clone https://github.com/ashd0wn/thyra.git
cp -r thyra/app/* /opt/thyra/app/
cp -r thyra/templates/* /opt/thyra/templates/
cp -r thyra/static/* /opt/thyra/static/
supervisorctl restart thyra-server thyra-viewer
```

---

## Contribuer

Les contributions sont bienvenues. Pour les changements importants, ouvrir une issue d'abord pour en discuter.

```bash
git clone https://github.com/ashd0wn/thyra.git
cd thyra
python3 -m venv venv
source venv/bin/activate
pip install flask gunicorn requests
THYRA_HOME=$(pwd) python3 app/server.py
```
L'interface est alors accessible sur `http://127.0.0.1:5000`.

---

## Licence

MIT — voir [LICENSE](LICENSE).

---

<div align="center">

*Thyra — θύρα — « la porte »*  
*Fait avec ☕ et un Raspberry Pi 3.*

**[ashd0wn](https://github.com/ashd0wn)**

</div>
