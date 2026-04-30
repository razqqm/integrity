// verify.js — browser-side helper for projects that publish manifests under
// https://github.com/razqqm/integrity.
//
// Usage:
//   import { verifyIntegrity } from 'https://raw.githubusercontent.com/razqqm/integrity/main/verify.js';
//   const result = await verifyIntegrity('tg.ilia.ae');
//
// Possible result.status values:
//   - 'verified'  — manifest fetched, bundle hashes match
//   - 'mismatch'  — manifest fetched, at least one bundle hash differs
//   - 'offline'   — manifest could not be fetched (network, 404, parse error)
//   - 'unknown'   — manifest fetched but no checkable bundle could be located
//                   (e.g. site has no main-*.js entry to compare against)
//
// The helper is intentionally framework-free and dependency-free so any project
// can pull it via a single ES-module import.

const RAW_BASE = 'https://raw.githubusercontent.com/razqqm/integrity/main/projects';

function manifestUrl(project) {
    return `${RAW_BASE}/${encodeURIComponent(project)}/manifest.json`;
}

async function sha256Hex(buffer) {
    const digest = await crypto.subtle.digest('SHA-256', buffer);
    return Array.from(new Uint8Array(digest))
        .map(b => b.toString(16).padStart(2, '0'))
        .join('');
}

async function findRunningBundle(name) {
    if (typeof performance === 'undefined') return null;
    const entries = performance.getEntriesByType('resource');
    const stem = name.replace(/\.js$/, '');
    const re = new RegExp(`/${stem}(?:-[A-Z0-9]+)?\\.js(?:\\?.*)?$`);
    return entries.find(e => re.test(e.name))?.name ?? null;
}

async function hashUrl(url) {
    const resp = await fetch(url, { cache: 'force-cache' });
    if (!resp.ok) throw new Error(`fetch ${url}: ${resp.status}`);
    const buf = await resp.arrayBuffer();
    return { sha256: await sha256Hex(buf), size: buf.byteLength };
}

export async function fetchManifest(project, { signal } = {}) {
    const url = manifestUrl(project);
    const resp = await fetch(url, { cache: 'no-cache', signal });
    if (!resp.ok) throw new Error(`manifest ${url}: ${resp.status}`);
    return resp.json();
}

export async function verifyIntegrity(project, { signal } = {}) {
    let manifest;
    try {
        manifest = await fetchManifest(project, { signal });
    } catch (err) {
        return { status: 'offline', error: String(err) };
    }

    const checks = [];
    for (const bundle of manifest.bundles ?? []) {
        const url = bundle.url ?? await findRunningBundle(bundle.name);
        if (!url) {
            checks.push({ name: bundle.name, status: 'unknown', reason: 'bundle not found in this page' });
            continue;
        }
        try {
            const { sha256, size } = await hashUrl(url);
            const ok = sha256 === bundle.sha256;
            checks.push({
                name: bundle.name,
                url,
                expected: bundle.sha256,
                actual: sha256,
                size,
                status: ok ? 'verified' : 'mismatch'
            });
        } catch (err) {
            checks.push({ name: bundle.name, url, status: 'offline', error: String(err) });
        }
    }

    let status = 'unknown';
    if (checks.some(c => c.status === 'mismatch')) status = 'mismatch';
    else if (checks.length && checks.every(c => c.status === 'verified')) status = 'verified';
    else if (checks.length && checks.some(c => c.status === 'offline')) status = 'offline';

    return { status, manifest, checks };
}
