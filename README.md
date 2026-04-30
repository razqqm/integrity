# integrity

Public **deployment integrity manifests** for projects maintained by [@razqqm](https://github.com/razqqm).

This repository serves a single purpose: publish, in plain sight, the cryptographic
fingerprint of what is currently deployed for each project. A site can fetch its own
manifest from this repo at runtime, compute the same hash from the bundle running in
the visitor's browser, and report whether the two match.

It is intentionally minimal: no build step, no CI, no signatures. The only thing
that matters is that the manifest URL is **public** and **stable**, while the source
codebases of the projects can remain private.

## Why this exists

The projects themselves are private repositories — auditors cannot click through to
GitHub source to verify that what runs in the browser matches what was published.
Publishing only the *hashes* on a separate, public repo gives anyone three things
without exposing the source:

1. **A public commitment.** Each deploy writes a manifest entry here. The git history
   of this repo is therefore a public, append-only log of every deployment.
2. **A way to verify in-page integrity claims.** A site reading "deployed: a1b2c3d"
   can be cross-checked: visit the corresponding project's `manifest.json`, confirm
   the same commit and hash.
3. **Independent observation.** Even if the project's server is later compromised
   to lie about what it is serving, an observer can still see the *true* last
   deploy here and notice the mismatch.

## Repository layout

```
projects/
  <hostname>/
    manifest.json         # current deployed manifest (always points at HEAD)
    history/              # one file per past deploy, keyed by commit SHA
      <commit-sha>.json
schema/
  manifest.schema.json    # JSON Schema for manifest.json
verify.js                 # tiny browser-side helper any project can import
```

Stable manifest URL for any project:

```
https://raw.githubusercontent.com/razqqm/integrity/main/projects/<hostname>/manifest.json
```

## Manifest format

```json
{
  "project": "tg.ilia.ae",
  "commit": "1bf2ac5",
  "commitFull": "1bf2ac5...",
  "branch": "main",
  "builtAt": "2026-04-30T18:37:14Z",
  "publishedAt": "2026-04-30T18:38:02Z",
  "bundles": [
    {
      "name": "main.js",
      "url": "https://tg.ilia.ae/main-XYZ.js",
      "sha256": "ab12cd34..."
    }
  ],
  "sourceRepoVisibility": "private",
  "publicSourceUrl": null
}
```

`sha256` is hex-encoded SHA-256 over the raw bytes of the deployed file. Easy to
recompute from the command line:

```sh
curl -sL https://tg.ilia.ae/main-XYZ.js | shasum -a 256
```

…or in the browser via `crypto.subtle.digest('SHA-256', buffer)`.

## How a project consumes this

```js
import { verifyIntegrity } from 'https://raw.githubusercontent.com/razqqm/integrity/main/verify.js';

const result = await verifyIntegrity('tg.ilia.ae');
// → { status: 'verified' | 'mismatch' | 'offline' | 'unknown',
//     manifest, runningSha256, ... }
```

See [`verify.js`](./verify.js) for the full surface.

## How a manifest is published

Each project's deploy script (or CI job) computes its own bundle SHA-256, opens a
PR (or pushes directly) into this repo, and the new `manifest.json` becomes the
public commitment for that deploy. Old manifests are kept under `history/` so the
log is append-only.

A reference helper script lives at [`scripts/publish.sh`](./scripts/publish.sh):

```sh
./scripts/publish.sh tg.ilia.ae \
    --commit 1bf2ac5 \
    --commit-full 1bf2ac5...  \
    --branch main \
    --bundle 'dist/browser/main-XYZ.js|https://tg.ilia.ae/main-XYZ.js|main.js'
```

The `--bundle` spec is `<local-path>|<public-url>|<logical-name>`, separated
by `|` so URLs containing `:` parse cleanly.

## Trust model — what this gives you, what it does not

This repository is a **public commitment**, not a cryptographic guarantee. The
integrity story relies on:

- HTTPS to `raw.githubusercontent.com` — visitors trust GitHub's TLS.
- The `razqqm` GitHub account not being compromised. Anyone publishing a fake
  manifest under this repo would have to take over that account first.
- The site's served bundle being identical, byte-for-byte, to what the manifest
  describes. A SHA-256 mismatch is a strong signal that something between the
  build server and the visitor's browser has been modified.

What it does **not** do:

- It does not prove the *source code* matches public expectations — the project
  repo is private. Verification is "what was deployed is consistent with what was
  publicly committed", not "what was deployed is what you would have audited."
- It does not protect against an attacker who controls both the project server
  *and* the GitHub account at the same time.

For stronger guarantees (cryptographic signatures, transparency log inclusion),
see [Sigstore](https://www.sigstore.dev/) — this repo can be upgraded later to
host signed bundles in the same place.

## License

Public domain (CC0-1.0). Manifests are factual data; do whatever you want with them.
