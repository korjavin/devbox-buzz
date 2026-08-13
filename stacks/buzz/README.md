# buzz relay stack (vendored)

Vendored from [block/buzz](https://github.com/block/buzz) `deploy/compose/`
at commit **`0571f5455b1b2aeea7334082f0df9d1f19b22f7d`** (upstream `main`,
2026-08-13). Upstream docs for this bundle:
<https://github.com/block/buzz/blob/main/deploy/compose/README.md>.

`compose.yml` and `run.sh` are byte-for-byte upstream (plus a provenance
comment). Adaptations, all local and all commented in place:

- `compose.caddy.yml` — upstream `!reset`s the relay port publish when Caddy
  terminates TLS. We `!override` it down to `127.0.0.1:<port>:3000` instead,
  because a host-side agent process connects to `ws://127.0.0.1:<port>`. Also
  passes `ACME_EMAIL` to Caddy.
- `Caddyfile` — global block with `email {$ACME_EMAIL}` for ACME registration.
- `.env.example` is not vendored: `ansible/roles/buzz/templates/env.j2` is the
  adapted copy and is the only thing that writes `/opt/buzz/.env`.
- `compose.dev.yml` is not vendored (local admin ports/tools, not wanted here).

The image is pinned in the role defaults to `ghcr.io/block/buzz:sha-0571f54`,
which is the image built from the same commit (digest
`sha256:72afcc47275e4ec819ddb2d84166eb452fcfd04bb3c1f7068c03e439cd9f2776`, the
same one `:main` pointed at when this was vendored).

Requires Docker Compose **v2.24.4+** for the `!override` / `!reset` merge tags.

Deployment is `ansible/roles/buzz`; nothing here should be run by hand except
`./run.sh` operator commands (`add-member`, `logs`, `upgrade`, `backup-hint`).
