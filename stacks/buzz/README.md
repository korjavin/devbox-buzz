# buzz relay stack (vendored)

Vendored from [block/buzz](https://github.com/block/buzz) `deploy/compose/`
at commit **`0571f5455b1b2aeea7334082f0df9d1f19b22f7d`**; last re-checked
against upstream `main` at `7f61cf431af1d8f0480a0baf525881a12f2be7f2`
(2026-08-17 — `deploy/compose/` unchanged since 2026-07-30, so the vendored
files are still byte-current). Upstream docs for this bundle:
<https://github.com/block/buzz/blob/main/deploy/compose/README.md>.

`compose.yml` and `run.sh` are byte-for-byte upstream (plus a provenance
comment). Adaptations, all local and all commented in place:

- `compose.caddy.yml` — upstream `!reset`s the relay port publish when Caddy
  terminates TLS. We `!override` it down to `127.0.0.1:<port>:3000` instead,
  because a host-side agent process connects to `ws://127.0.0.1:<port>`. Also
  passes `ACME_EMAIL` to Caddy.
- `compose.caddy.yml` — adds a `pair-relay` service. NIP-AB device pairing is a
  separate binary (`/usr/local/bin/buzz-pair-relay`) that upstream's compose
  bundle never runs; only `deploy/charts` does (`pairingRelay.*`). Without it
  the desktop's pairing QR points at a 404.
- `Caddyfile` — global block with `email {$ACME_EMAIL}` for ACME registration,
  plus a `/pair` route to `pair-relay:5000` (everything else goes to the relay).
  `ansible/roles/buzz` also sets `BUZZ_PAIRING_RELAY_URL=wss://<host>/pair`, which
  the relay advertises as `pairing_relay_url` in its NIP-11 document — that is
  how clients discover the pairing endpoint. Same domain, no extra DNS record.
- `.env.example` is not vendored: `ansible/roles/buzz/templates/env.j2` is the
  adapted copy and is the only thing that writes `/opt/buzz/.env`.
- `compose.dev.yml` is not vendored (local admin ports/tools, not wanted here).

The image is pinned in the role defaults to `ghcr.io/block/buzz:sha-7f61cf4`,
built from upstream `main` `7f61cf43` (index digest
`sha256:4021d7c65e5c79979dc92345c6f8325a347cddb44f5bfea1897b8663758fa292`, the
same one `:main` pointed at on 2026-08-17).

Requires Docker Compose **v2.24.4+** for the `!override` / `!reset` merge tags.

Deployment is `ansible/roles/buzz`; nothing here should be run by hand except
`./run.sh` operator commands (`add-member`, `logs`, `upgrade`, `backup-hint`).
