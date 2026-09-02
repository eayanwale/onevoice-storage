# direct-download-worker

Phase 1 of #91 (see #92). Streams a B2 object straight to the client instead
of Nextcloud/PHP proxying it through the Bluehost VPS. This directory is
**not wired into Nextcloud yet** — it's an isolated component, deployed to a
throwaway subdomain, tested on its own before anything real depends on it.

## How it works

1. Something Nextcloud trusts (Phase 2, #93 — not built yet) mints a token:
   `base64url(JSON payload).base64url(HMAC-SHA256 signature)`, where the
   payload is `{ key, exp, filename? }`.
2. A client requests `https://<worker-url>/?t=<token>`.
3. This Worker verifies the signature and expiry using a secret only it and
   Nextcloud know. If it doesn't check out, nothing is served — the Worker
   makes no authorization decisions of its own, it only checks that
   Nextcloud already made one.
4. On success, it signs a request to B2 (SigV4, via `aws4fetch`) using a
   **read-only** B2 application key, and streams the object back.

## Status: Phase 1 complete and validated (#92 closed)

Deployed to a real `*.workers.dev` test URL, against the real "OneVoice" B2
bucket, and confirmed end-to-end:

- Valid token -> `200`, correct file streamed, correct `Content-Disposition`
  filename, `Server: cloudflare` in the response (the VPS was never touched)
- Expired token -> `403`
- Tampered token (one character changed) -> `403`
- Rotating `WORKER_SIGNING_SECRET` immediately invalidates every
  previously-issued token, as expected

## What's verified so far

`node test-token.mjs` — pure token logic, no Cloudflare/B2 involved. Covers
the security-critical cases: tampered payload rejected, wrong secret
rejected, expired token rejected, malformed input rejected. Run it any time
this logic changes.

Plus the real deployed-environment checks above, via `mint-test-token.mjs` +
curl against the live test Worker.

## Gotchas hit during the real deployment (useful for Phase 3/4)

- **Windows PowerShell blocks `npm`/`npx`/`wrangler` by default** (they ship
  as `.ps1` scripts). Fix: `Set-ExecutionPolicy -ExecutionPolicy Bypass
  -Scope Process` in the session, or call `npm.cmd`/`npx.cmd` explicitly.
- **A narrowly-scoped token (Workers Scripts: Edit only) can't call
  Cloudflare's `/memberships` endpoint**, which `wrangler` uses to guess
  which account to deploy to. Fix: set `account_id` explicitly in
  `wrangler.toml` (not sensitive — Cloudflare shows it openly in the
  dashboard) so wrangler never needs to ask. Already done in this repo's
  `wrangler.toml`.
- **Never run `mint-test-token.mjs` with the secret as a visible argument
  and then paste the full terminal output somewhere it'll be retained** —
  the secret is a CLI argument, so it ends up in shell history and anywhere
  the output gets copied. Rotate immediately if that happens; it's cheap.

## What's needed before this can actually be deployed and tested for real

Two things, neither of which exist yet, and neither of which should be typed
into chat/committed anywhere:

1. **A Cloudflare API token** with Workers Scripts edit permission (create
   one in the Cloudflare dashboard, scoped narrowly — not the Tunnel token,
   which can't deploy Workers). Used only to `wrangler deploy`.
2. **A new, read-only B2 application key**, scoped to only the relevant
   bucket, created via the Backblaze B2 web console (the bucket-scoped keys
   already in `onevoice.env` can't self-mint a narrower key — this has to be
   a fresh one from the console). Capabilities needed: `listFiles`,
   `readFiles` only. Never write/delete.

Once both exist, set the three secrets (never in `wrangler.toml`):

```
wrangler secret put WORKER_SIGNING_SECRET
wrangler secret put B2_READONLY_KEY_ID
wrangler secret put B2_READONLY_APPLICATION_KEY
```

...and fill in the real `B2_BUCKET` in `wrangler.toml` before `wrangler deploy`.

## Deploying to the test subdomain

Deploy under a name/route that nothing in Nextcloud points to yet
(`onevoice-direct-download-test`, per `wrangler.toml`) — this stays
disconnected from production until Phase 3 (#94) deliberately wires it up.

```
npm install
wrangler deploy
```

Then hand-test with curl: a token minted by `test-token.mjs`'s `mintToken()`
should succeed; an expired or tampered one should return 403.

## Explicitly not handled yet

- Range-request-heavy video scrubbing hasn't been load-tested (basic Range
  passthrough exists in the code, untested end-to-end)
- Nothing here mints tokens from real Nextcloud state — that's #93
- Nothing here is wired into production — that's #94
