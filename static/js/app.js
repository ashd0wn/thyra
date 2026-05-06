/* app.js — Thyra shared utilities */

'use strict';

const API = {
  async get(url) {
    const r = await fetch(url);
    if (!r.ok) throw new Error(await r.text());
    return r.json();
  },
  async post(url, data) {
    const r = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
    });
    if (!r.ok) throw new Error(await r.text());
    return r.json();
  },
  async postForm(url, formData) {
    const r = await fetch(url, { method: 'POST', body: formData });
    if (!r.ok) throw new Error(await r.text());
    return r.json();
  },
  async put(url, data) {
    const r = await fetch(url, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
    });
    if (!r.ok) throw new Error(await r.text());
    return r.json();
  },
  async del(url) {
    const r = await fetch(url, { method: 'DELETE' });
    if (!r.ok) throw new Error(await r.text());
    return r.json();
  },
};

function toast(msg, type = 'info') {
  const el = document.createElement('div');
  el.className = `flash flash-${type}`;
  el.textContent = msg;
  el.style.cssText = `
    position:fixed; bottom:20px; right:20px;
    z-index:9999; padding:10px 16px;
    border-radius:8px; font-size:.88rem; font-weight:500;
    animation: slideUp .2s ease;
    max-width: 360px;
    box-shadow: 0 4px 16px rgba(0,0,0,.4);
  `;
  document.body.appendChild(el);
  setTimeout(() => el.remove(), 3000);
}

function confirm_action(msg) {
  return window.confirm(msg);
}

// Auto-dismiss flash messages
document.querySelectorAll('.flash').forEach(el => {
  setTimeout(() => {
    el.style.opacity = '0';
    el.style.transition = 'opacity .4s';
    setTimeout(() => el.remove(), 400);
  }, 4000);
});
