/* settings.js — Thyra Settings page */
'use strict';

// ── Init ───────────────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
    checkApStatus();
});

// ── Sauvegarde des settings + changement de mot de passe ────────────────────
async function savePassword() {
    // 1. Changement de mot de passe si les champs sont remplis
    const currentPwd = q('#currentPwd').value;
    const newPwd     = q('#newPwd').value;
    const confirmPwd = q('#confirmPwd').value;

    if (newPwd || currentPwd) {
        if (!currentPwd) {
            toast('Entrez votre mot de passe actuel.', 'error'); return;
        }
        if (newPwd !== confirmPwd) {
            toast('Les mots de passe ne correspondent pas.', 'error'); return;
        }
        if (newPwd.length < 4) {
            toast('Mot de passe trop court (min 4 caractères).', 'error'); return;
        }
        try {
            await API.put('/api/users/me/password', {
                current_password: currentPwd,
                new_password:     newPwd,
            });
            toast('Mot de passe mis à jour.', 'success');
            q('#currentPwd').value = '';
            q('#newPwd').value     = '';
            q('#confirmPwd').value = '';
        } catch(e) {
            toast('Mot de passe actuel incorrect.', 'error');
            return;
        }
    }

    // 2. Soumission du formulaire settings
    // Les checkboxes non cochées ne sont pas envoyées en POST natif,
    // on gère manuellement pour garantir la valeur "0"
    const form = document.getElementById('settingsForm');

    // Ajouter des champs hidden pour les checkboxes non cochées
    const checkboxes = form.querySelectorAll('input[type=checkbox]');
    checkboxes.forEach(cb => {
        if (!cb.checked) {
            let hidden = form.querySelector(`input[type=hidden][name="${cb.name}"]`);
            if (!hidden) {
                hidden = document.createElement('input');
                hidden.type  = 'hidden';
                hidden.name  = cb.name;
                form.appendChild(hidden);
            }
            hidden.value = '0';
        }
    });

    form.submit();
}

function cancelSettings() {
    location.reload();
}

// ── Système ────────────────────────────────────────────────────────────────
async function reloadViewer() {
    try {
        await API.post('/api/system/reload_viewer', {});
        toast('Viewer rechargé.', 'success');
    } catch(e) { toast(e.message, 'error'); }
}

async function confirmReboot() {
    if (!confirm('Redémarrer le Raspberry Pi maintenant ?')) return;
    try {
        await API.post('/api/system/reboot', {});
        toast('Redémarrage en cours…', 'info');
    } catch(e) { toast(e.message, 'error'); }
}

// ── AP Status ──────────────────────────────────────────────────────────────
async function checkApStatus() {
    try {
        const d = await API.get('/api/ap/status');
        const box = q('#apStatusText');
        if (!box) return;
        box.textContent = d.running
            ? `✓ Actif — SSID : ${d.ssid}  ·  IP : 192.168.73.1`
            : '✗ Inactif';
        box.style.color = d.running ? 'var(--success)' : 'var(--text-muted)';
    } catch { /* ignore */ }
}

async function applyAP() {
    const enabled = document.querySelector('[name="ap_enabled"]').value;
    const ssid    = document.querySelector('[name="ap_ssid"]').value;
    const pass    = document.querySelector('[name="ap_password"]').value;
    const channel = document.querySelector('[name="ap_channel"]').value;
    try {
        const d = await API.post('/api/ap/toggle', {
            enabled: enabled === '1', ssid, password: pass, channel,
        });
        toast(d.status || 'AP mis à jour.', 'success');
        setTimeout(checkApStatus, 2000);
    } catch(e) { toast(e.message, 'error'); }
}

// ── Changement MDP (modal admin pour autres users) ────────────────────────
let changePwdUid = null;

function openChangePassword(uid, username) {
    changePwdUid = uid;
    q('#changePwdSubtitle').textContent = `Utilisateur : ${username}`;
    q('#adminNewPwd').value     = '';
    q('#adminConfirmPwd').value = '';
    show('changePwdModal');
}
function closeChangePwd() { hide('changePwdModal'); changePwdUid = null; }

async function submitChangePwd() {
    const newP = q('#adminNewPwd').value;
    const conf = q('#adminConfirmPwd').value;
    if (newP !== conf) { toast('Les mots de passe ne correspondent pas.', 'error'); return; }
    if (newP.length < 4) { toast('Trop court.', 'error'); return; }
    try {
        await API.put(`/api/users/${changePwdUid}/password`, { password: newP });
        toast('Mot de passe mis à jour.', 'success');
        closeChangePwd();
    } catch(e) { toast(e.message, 'error'); }
}

// ── Gestion utilisateurs ──────────────────────────────────────────────────
function openAddUser()  { show('addUserModal'); }
function closeAddUser() { hide('addUserModal'); }

async function createUser() {
    const username = q('#newUsername').value.trim();
    const password = q('#newPassword').value;
    const role     = q('#newRole').value;
    if (!username || !password) {
        toast('Identifiant et mot de passe requis.', 'error'); return;
    }
    try {
        await API.post('/api/users', { username, password, role });
        toast('Utilisateur créé.', 'success');
        setTimeout(() => location.reload(), 600);
    } catch(e) { toast(e.message, 'error'); }
}

async function deleteUser(id, name) {
    if (!confirm(`Supprimer l'utilisateur "${name}" ?`)) return;
    try {
        await API.del(`/api/users/${id}`);
        toast('Utilisateur supprimé.', 'success');
        setTimeout(() => location.reload(), 600);
    } catch(e) { toast(e.message, 'error'); }
}

// ── WiFi wizard ────────────────────────────────────────────────────────────
function openWifiWizard() {
    resetWifiWizard();
    show('wifiWizardModal');
    scanWifi();
}
function closeWifiWizard() { hide('wifiWizardModal'); }

function dismissWizard() {
    const banner = document.getElementById('wifiWizard');
    if (banner) banner.style.display = 'none';
}

function resetWifiWizard() {
    show_el('wifiStep1');
    hide_el('wifiStep2');
    hide_el('wifiStep3');
    hide_el('wifiStep4');
    show_el('wifiWizardActions');
}

async function scanWifi() {
    const sel = q('#wifiSsidSelect');
    sel.innerHTML = '<option value="">Scan en cours…</option>';
    try {
        const networks = await API.get('/api/system/scan_wifi');
        sel.innerHTML = '<option value="">— Sélectionner un réseau —</option>';
        networks.forEach(n => {
            const opt = document.createElement('option');
            opt.value = n.ssid;
            opt.textContent = `${n.ssid}${n.encrypted ? ' 🔒' : ''} (${n.quality || 0}%)`;
            sel.appendChild(opt);
        });
    } catch(e) {
        sel.innerHTML = '<option value="">Scan impossible — saisir manuellement</option>';
    }
}

async function connectWifi() {
    const ssidSel    = q('#wifiSsidSelect').value;
    const ssidManual = q('#wifiSsidManual').value.trim();
    const ssid = ssidSel || ssidManual;
    const pwd  = q('#wifiPassword').value;

    if (!ssid) { toast('Sélectionnez ou saisissez un SSID.', 'error'); return; }

    hide_el('wifiStep1');
    hide_el('wifiWizardActions');
    show_el('wifiStep2');

    try {
        const r = await API.post('/api/system/connect_wifi', { ssid, password: pwd });
        hide_el('wifiStep2');

        if (r.status === 'connected') {
            q('#wifiNewIp').textContent  = r.ip || '?';
            q('#wifiNewUrl').textContent = `http://${r.ip}/`;
            show_el('wifiStep3');
        } else {
            q('#wifiErrMsg').textContent = r.detail || 'Erreur inconnue.';
            show_el('wifiStep4');
            show_el('wifiWizardActions');
        }
    } catch(e) {
        hide_el('wifiStep2');
        q('#wifiErrMsg').textContent = e.message;
        show_el('wifiStep4');
        show_el('wifiWizardActions');
    }
}

// ── Helpers ────────────────────────────────────────────────────────────────
function q(sel)        { return document.querySelector(sel); }
function show(id)      { document.getElementById(id).style.display = 'flex'; }
function hide(id)      { document.getElementById(id).style.display = 'none'; }
function show_el(id)   { const el = document.getElementById(id); if (el) el.style.display = ''; }
function hide_el(id)   { const el = document.getElementById(id); if (el) el.style.display = 'none'; }
