/* schedule.js — Thyra Schedule Overview */
'use strict';

let allAssets   = [];
let currentTab  = 'upload';
let editingId   = null;
let viewerIndex = 0;  // pour prev/next

// ── Init ───────────────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
    // Dropzone
    const dz = document.getElementById('dropzone');
    if (dz) {
        dz.addEventListener('click', () => q('#fileInput').click());
        dz.addEventListener('dragover', e => { e.preventDefault(); dz.classList.add('drag-over'); });
        dz.addEventListener('dragleave', () => dz.classList.remove('drag-over'));
        dz.addEventListener('drop', e => {
            e.preventDefault();
            dz.classList.remove('drag-over');
            if (e.dataTransfer.files[0]) {
                const dt = new DataTransfer();
                dt.items.add(e.dataTransfer.files[0]);
                q('#fileInput').files = dt.files;
                previewFile(q('#fileInput'));
            }
        });
    }
    // Charge la liste en mémoire pour le modal d'édition
    loadAssetsData();
});

async function loadAssetsData() {
    try {
        allAssets = await API.get('/api/assets');
    } catch(e) {
        console.warn('Could not preload assets:', e);
    }
}

// ── Add modal ──────────────────────────────────────────────────────────────
function openAddModal() {
    document.getElementById('addModal').style.display = 'flex';
}
function closeAddModal() {
    document.getElementById('addModal').style.display = 'none';
    clearFile();
    q('#assetName').value     = '';
    q('#assetDuration').value = '10';
    q('#assetPlayFor').value  = 'manual';
    q('#dateFields').style.display = 'none';
}

function switchTab(tab) {
    currentTab = tab;
    document.querySelectorAll('.tab-bar .tab').forEach((b, i) => {
        b.classList.toggle('active', ['upload','url','web'][i] === tab);
    });
    ['upload','url','web'].forEach(t => {
        const el = document.getElementById('tab-' + t);
        if (el) el.style.display = t === tab ? '' : 'none';
    });
}

function toggleDateFields() {
    const pf = q('#assetPlayFor').value;
    q('#dateFields').style.display = pf === 'scheduled' ? 'flex' : 'none';
}
function toggleEditDateFields() {
    const pf = q('#editPlayFor').value;
    q('#editDateFields').style.display = pf === 'scheduled' ? 'flex' : 'none';
}

function previewFile(input) {
    if (!input.files.length) return;
    const f = input.files[0];
    q('#previewName').textContent = `${f.name} (${(f.size/1024/1024).toFixed(1)} Mo)`;
    q('#filePreview').style.display = 'flex';
    q('#dropzone').style.display = 'none';
    if (!q('#assetName').value)
        q('#assetName').value = f.name.replace(/\.[^.]+$/, '');
}
function clearFile() {
    const fi = q('#fileInput');
    if (fi) fi.value = '';
    const preview = q('#filePreview');
    if (preview) preview.style.display = 'none';
    const dz = q('#dropzone');
    if (dz) dz.style.display = '';
    const name = q('#assetName');
    if (name) name.value = '';
}

async function submitAsset() {
    const btn = q('#submitBtn');
    btn.disabled = true;
    btn.textContent = 'Envoi…';

    try {
        const fd = new FormData();
        fd.append('name',       q('#assetName').value.trim());
        fd.append('duration',   q('#assetDuration').value);
        fd.append('is_active',  '1');
        fd.append('play_for',   q('#assetPlayFor').value);

        const sd = q('#assetStartDate').value;
        const ed = q('#assetEndDate').value;
        if (sd) fd.append('start_date', sd);
        if (ed) fd.append('end_date',   ed);

        if (currentTab === 'upload') {
            const file = q('#fileInput').files[0];
            if (!file) throw new Error('Sélectionnez un fichier.');
            fd.append('file', file);
            const ext = file.name.split('.').pop().toLowerCase();
            fd.append('asset_type',
                ['mp4','webm','mkv','avi','mov','m4v','flv','ts'].includes(ext) ? 'video' :
                ['html','htm'].includes(ext) ? 'webpage' : 'image');
        } else if (currentTab === 'url') {
            const uri = q('#urlInput').value.trim();
            if (!uri) throw new Error('Entrez une URL.');
            fd.append('uri', uri);
            const ext = uri.split('?')[0].split('.').pop().toLowerCase();
            fd.append('asset_type',
                ['mp4','webm','mkv','avi','mov','m4v'].includes(ext) ? 'video' : 'image');
        } else {
            const uri = q('#webInput').value.trim();
            if (!uri) throw new Error('Entrez une URL de page web.');
            fd.append('uri', uri);
            fd.append('asset_type', 'webpage');
        }

        await API.postForm('/api/assets', fd);
        toast('Asset ajouté.', 'success');
        closeAddModal();
        setTimeout(() => location.reload(), 600);
    } catch(e) {
        toast('Erreur : ' + e.message, 'error');
    } finally {
        btn.disabled = false;
        btn.textContent = 'Add Asset';
    }
}

// ── Edit modal ──────────────────────────────────────────────────────────────
async function editAsset(id) {
    // Recharge depuis l'API pour avoir les données fraîches
    try {
        const a = await API.get(`/api/assets/${id}`);
        editingId = id;

        q('#editName').value     = a.name;
        q('#editLocation').textContent = a.uri || '—';
        q('#editType').value     = a.asset_type;
        q('#editPlayFor').value  = a.play_for || 'manual';
        q('#editDuration').value = a.duration;

        // Dates : format datetime-local = "YYYY-MM-DDTHH:MM"
        q('#editStartDate').value = a.start_date ? a.start_date.slice(0,16) : '';
        q('#editEndDate').value   = a.end_date   ? a.end_date.slice(0,16)   : '';

        toggleEditDateFields();
        document.getElementById('editModal').style.display = 'flex';
    } catch(e) {
        toast('Impossible de charger l\'asset : ' + e.message, 'error');
    }
}
function closeEditModal() {
    document.getElementById('editModal').style.display = 'none';
    editingId = null;
}
async function saveEdit() {
    if (!editingId) return;
    try {
        await API.put(`/api/assets/${editingId}`, {
            name:       q('#editName').value.trim(),
            duration:   parseInt(q('#editDuration').value),
            play_for:   q('#editPlayFor').value,
            start_date: q('#editStartDate').value || null,
            end_date:   q('#editEndDate').value   || null,
        });
        toast('Asset mis à jour.', 'success');
        closeEditModal();
        setTimeout(() => location.reload(), 600);
    } catch(e) {
        toast('Erreur : ' + e.message, 'error');
    }
}

// ── Toggle active ─────────────────────────────────────────────────────────
async function toggleAsset(id, active) {
    try {
        await API.put(`/api/assets/${id}`, { is_active: active ? 1 : 0 });
        // Pas de reload complet : juste déplace visuellement la ligne
        setTimeout(() => location.reload(), 400);
    } catch(e) {
        toast('Erreur : ' + e.message, 'error');
    }
}

// ── Delete ────────────────────────────────────────────────────────────────
async function deleteAsset(id, name) {
    if (!confirm(`Supprimer "${name}" ? Cette action est irréversible.`)) return;
    try {
        await API.del(`/api/assets/${id}`);
        toast('Asset supprimé.', 'success');
        document.getElementById(`row-${id}`)?.remove();
    } catch(e) {
        toast('Erreur : ' + e.message, 'error');
    }
}

// ── Download ──────────────────────────────────────────────────────────────
function downloadAsset(id, uri) {
    if (!uri || uri.startsWith('http')) {
        window.open(uri, '_blank');
    } else {
        const a = document.createElement('a');
        a.href = uri;
        a.download = uri.split('/').pop();
        a.click();
    }
}

// ── Previous / Next (contrôle viewer à chaud) ─────────────────────────────
async function prevAsset() {
    try {
        await API.post('/api/system/reload_viewer', { direction: 'prev' });
        toast('← Asset précédent', 'info');
    } catch(e) { toast(e.message, 'error'); }
}
async function nextAsset() {
    try {
        await API.post('/api/system/reload_viewer', { direction: 'next' });
        toast('Asset suivant →', 'info');
    } catch(e) { toast(e.message, 'error'); }
}

// ── Helpers ───────────────────────────────────────────────────────────────
function q(sel) { return document.querySelector(sel); }
