# buzz_agent

Attaches Claude Code to the buzz relay running on this host, unattended:

```
relay (docker, 127.0.0.1) --ws/NIP-42--> buzz-acp --stdio/ACP--> claude-agent-acp --> Claude Code
                                             ^                          |
                                             +--- systemd, restarts -----+
```

The agent replies with the `buzz` CLI, which the harness's base prompt tells it
to use; the CLI reads the same `BUZZ_RELAY_URL` / `BUZZ_PRIVATE_KEY`
(it rewrites `ws://` to `http://` internally, so one URL serves both).

## Where the binaries come from

`buzz-acp` is not on crates.io or npm, and it is **not** in the relay image
(`Dockerfile` builds only `buzz-relay`, `buzz-admin`, `buzz-pair-relay`).
Upstream ships it prebuilt in the **sprig** release: a static musl multicall
binary that switches personality on `argv[0]` — `buzz-acp`, `buzz-agent`,
`buzz-dev-mcp`, `buzz`. The role unpacks
`sprig-x86_64-unknown-linux-musl.tar.gz` into `~/.local/lib/sprig` and symlinks
`buzz-acp` and `buzz` into `~/.local/bin`. Integrity is the sibling `.sha256`
asset, enforced by `get_url` on every run.

`buzz_agent_sprig_release` defaults to `sprig-latest`, which is a *rolling*
release tracking upstream `main`; pin it to a `sprig-v*` tag when you want a
frozen agent.

The ACP adapter itself (`@agentclientprotocol/claude-agent-acp`) is an npm
global installed as `devbox_user` (npm's prefix is `~/.local`, see
`roles/devtools`). Claude Code is already installed by `roles/devtools` — this
role does not reinstall it.

## Identity and closed-relay admission

The relay runs closed (`BUZZ_REQUIRE_RELAY_MEMBERSHIP=true`): NIP-42 auth is
rejected with `restricted: not a relay member` unless the pubkey has a row in
the `relay_members` Postgres table. `RELAY_OWNER_PUBKEY` is seeded at relay
boot; every other pubkey — including this agent — has to be admitted
explicitly. There is no env allowlist and no REST endpoint for it.

Upstream's mechanism is `buzz-admin`, which lives inside the relay image and
needs the relay's `DATABASE_URL`, `REDIS_URL` and `BUZZ_RELAY_PRIVATE_KEY`, so
the role runs it *inside the relay container* — the same thing upstream's
`deploy/compose/run.sh add-member` does:

```bash
docker exec <relay> buzz-admin generate-key                    # once, persisted
docker exec <relay> buzz-admin add-member --pubkey <agent hex> --role member
```

`add-member` inserts the row and publishes a kind:13534 NIP-43 membership
roster over Redis so live clients see it immediately. It is idempotent — a
second run prints `already a member`, which the role treats as unchanged.

**The relay stack must set `BUZZ_RELAY_PRIVATE_KEY`** (it is commented out in
upstream's `.env.example`): without a stable relay signing key, `add-member`
refuses to run.

The keypair is generated once and persisted:

| Path | Mode | Contents |
|---|---|---|
| `~/.config/buzz-agent/secret_key` | 0600 | agent Nostr private key (hex) |
| `~/.config/buzz-agent/public_key` | 0644 | agent Nostr pubkey (hex) — mention this to talk to it |
| `~/.config/buzz-agent/env` | 0600 | systemd `EnvironmentFile`: private key + OAuth token |

Re-running the role never regenerates the keypair: a new key would be a new
identity and would lose the agent's membership, DMs and history. To rotate,
delete `secret_key` and re-run (then `remove-member` the old pubkey).

## Auth

There is no `ANTHROPIC_API_KEY` here. `claude_code_oauth_token` (from
`claude setup-token`) is required and lands **only** in the 0600
`EnvironmentFile`. `claude-agent-acp` runs on `@anthropic-ai/claude-agent-sdk`,
which lists `CLAUDE_CODE_OAUTH_TOKEN` among its credential env vars and only
falls back to `~/.claude/.credentials.json` when neither it nor
`ANTHROPIC_API_KEY` is set.

## Who the agent listens to

`buzz-acp`'s author gate defaults to `owner-only`, and **an agent with no
resolved owner drops every inbound event silently**. So the role requires
`buzz_relay_owner_pubkey` (64-char hex, the same key as the relay's
`RELAY_OWNER_PUBKEY`) and passes it as `BUZZ_ACP_AGENT_OWNER`. Set
`buzz_agent_respond_to: allowlist` plus `buzz_agent_respond_to_allowlist` to
add teammates, or `anyone` to open it up.

## Variables

See `defaults/main.yml`. Required: `claude_code_oauth_token`,
`buzz_relay_owner_pubkey` (unless `buzz_agent_respond_to` is `anyone`/`nobody`).

## Operating it

```bash
systemctl status buzz-agent
journalctl -u buzz-agent -f
docker exec $(docker ps -q -f label=com.docker.compose.project=buzz-prod \
                          -f label=com.docker.compose.service=relay) \
  buzz-admin list-members
```

In a channel, `@`-mention the agent's pubkey. The owner can also send
`!cancel`, `!rotate` or `!shutdown` (the harness consumes them; systemd
restarts after `!shutdown`).
