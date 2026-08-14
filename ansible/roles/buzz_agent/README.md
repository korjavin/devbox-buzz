# buzz_agent

Attaches coding agents to the buzz relay running on this host, unattended:

```
relay (docker, 127.0.0.1) --ws/NIP-42--> buzz-acp --stdio/ACP--> <adapter> --> Claude Code / Codex
                                             ^                          |
                                             +--- systemd, restarts -----+
```

One instance of that pipeline per entry in `buzz_agents` (default: `claude` and
`codex`), each with its own keypair, relay membership, kind:0 name and
`buzz-agent@<name>.service` unit. Adding a third is a list entry:

```yaml
buzz_agents:
  - { name: goose, adapter_npm: some-goose-acp, adapter_command: goose-acp, about: "..." }
```

The agents reply with the `buzz` CLI, which the harness's base prompt tells them
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

Each agent's ACP adapter (`adapter_npm`) is an npm global installed as
`devbox_user` (npm's prefix is `~/.local`, see `roles/devtools`). The CLIs the
adapters drive — `claude`, `codex` — are already installed by `roles/devtools`;
this role does not reinstall them.

## Identity and closed-relay admission

The relay runs closed (`BUZZ_REQUIRE_RELAY_MEMBERSHIP=true`): NIP-42 auth is
rejected with `restricted: not a relay member` unless the pubkey has a row in
the `relay_members` Postgres table. `RELAY_OWNER_PUBKEY` is seeded at relay
boot; every other pubkey — including these agents — has to be admitted
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

Each keypair is generated once and persisted, per agent:

| Path | Mode | Contents |
|---|---|---|
| `~/.config/buzz-agent-<name>/secret_key` | 0600 | agent Nostr private key (hex) |
| `~/.config/buzz-agent-<name>/public_key` | 0644 | agent Nostr pubkey (hex) — mention this to talk to it |
| `~/.config/buzz-agent-<name>/env` | 0600 | systemd `EnvironmentFile`: private key + credentials |
| `~/.config/buzz-agent-<name>/auth_tag` | 0644 | NIP-OA owner attestation (public) |
| `~/.config/buzz-agent-<name>/debug_channel` | 0644 | id of this agent's `debug-<name>` channel |
| `~/.config/buzz-agent-<name>/.profile_published`, `.intro_sent` | 0644 | one-shot markers |
| `~/.config/buzz-logs/{secret,public}_key` | 0600/0644 | the log forwarder's own identity |

Re-running the role never regenerates a keypair: a new key would be a new
identity and would lose that agent's membership, DMs and history. To rotate,
delete `secret_key` and re-run (then `remove-member` the old pubkey).

Boxes provisioned before this role took a `buzz_agents` list keep the claude
agent under `~/.config/buzz-agent` and a plain `buzz-agent.service`. The role
migrates that layout in place — unit stopped and removed, directory *moved* to
`~/.config/buzz-agent-claude` — so the pubkey survives. That migration runs
before the per-agent tasks on purpose: an empty config dir would mint a new
identity.

## Owner attribution: the app's "owner unavailable"

Buzz Desktop labels every agent message with who owns the agent, and shows
**"owner unavailable"** when it cannot work that out
(`desktop/src/features/messages/ui/MessageAgentOwner.tsx:45`, rendered for any
author with `isAgent` — including a plain `bot`-role channel member). What it
reads is **not** a profile field and not relay metadata: it is a valid NIP-OA
`auth` tag on the agent's own kind:0 event
(`desktop/src-tauri/src/nostr_convert.rs:58-84`,
`profile_valid_oa_owner_pubkey` → `nip_oa::verify_auth_tag`).

The tag is

```json
["auth", "<owner-pubkey-hex>", "<conditions>", "<sig-hex>"]
```

where the signature is BIP-340 Schnorr over
`SHA256("nostr:agent-auth:" + <agent-pubkey-hex> + ":" + <conditions>)`, **made
with the owner's secret key** (`crates/buzz-sdk/src/nip_oa.rs:109-116, 146-166`).
Self-attestation is rejected on both mint and verify (`nip_oa.rs:152-156`,
`:216-220`), so **the box cannot produce this itself** — the owner's key must
never live here. The role therefore takes the finished tag as input:

```yaml
buzz_agent_auth_tags:
  claude: '["auth","<owner_hex>","","<sig_hex>"]'
  codex:  '["auth","<owner_hex>","","<sig_hex>"]'
```

**One-shot command for the owner, on the owner's own machine** (needs a
checkout of block/buzz and a rust toolchain; `conditions` stays empty — the
desktop does not evaluate conditions but `buzz users get --owner me` reports
`condition_mismatch` for anything else):

```bash
cargo run -p buzz-sdk --release --example compute_auth_tag -- \
  "$(kv get secrets/buzz-owner-nsec-hex)" <agent_pubkey_hex> ""
# -> ["auth","<owner_hex>","","<sig_hex>"]   (one per agent pubkey)
```

Agent pubkeys are in `~devbox/.config/buzz-agent-<name>/public_key`. Feed the
results back as `-e '{"buzz_agent_auth_tags": {...}}'` (stash them, e.g.
`kv put secrets/buzz-auth-tag-claude`). The tag is public data — it is
published in the kind:0 — so it does not need vault treatment.

### The trade-off: it hides the agent from the @mention picker

**`buzz_agent_auth_tags` is empty by default, and that is deliberate.** A valid
owner tag on the kind:0 is exactly what makes the desktop treat the author as
an agent (`is_agent: owner_pubkey.is_some()`,
`desktop/src-tauri/src/nostr_convert.rs:335-346`) — and the mention picker hides
an agent it cannot find in a directory:

```ts
if (!isAgent) return "allow";
if (!directoryReady || ownerOnly === undefined) return "unknown";
if (!mentionableAgentPubkeys.has(normalized)) return "deny";
```
(`desktop/src/features/agents/lib/agentAutocompleteEligibility.ts:116-126`,
used by `useMentions.ts:257`.) `mentionableAgentPubkeys` is the desktop's own
managed agents plus **kind:10100 agent-profile** records whose `respond_to` is
`anyone`/`allowlist` and whose `channel_ids` contain the channel
(`getMentionableAgentPubkeys`, `relayAgentCanRespondInChannel`). Agents deployed
by this role are neither: they are self-hosted, `owner-only`, and nothing here
publishes a kind:10100 (the relay has none — the only writer is Buzz Desktop,
and `buzz channels set-add-policy` writes a policy-only one that would make
things worse). So turning attribution on trades the owner label for the picker
entry in any channel where the agent is a plain `member`; in channels where its
role is `bot` the picker already hides it either way (`member.role === "bot"`
sets `isAgent` on its own, `useMentions.ts:327-332`).

Rollback is one variable: drop the agent from `buzz_agent_auth_tags` and
converge — the role removes `auth_tag` and republishes a kind:0 with no tag,
byte-identical to the pre-attestation profile.

**What actually fixes both:** a kind:10100 agent-profile record for these
agents (upstream would have to let something other than the desktop publish
one), or upstream not gating self-hosted agents out of the picker.

Note that the **observer stream does not need the attestation** — buzz-acp
resolves its owner from `BUZZ_ACP_AGENT_OWNER`, and the relay-side mapping is
backfilled directly (below). Attribution is the label, and only the label.

Given the tag, the role writes it to `<agent dir>/auth_tag`, republishes the
kind:0 with `BUZZ_AUTH_TAG` set (the CLI injects it into every event it signs,
`crates/buzz-cli/src/client.rs:583-612`), and puts it in the harness
environment, where buzz-acp uses it as its owner source
(`owner resolved from BUZZ_AUTH_TAG` in the journal) and attaches it to the
NIP-42 AUTH event. Changing the tag deletes the `.profile_published` marker so
the profile is republished; a tag that does not verify against the agent's
pubkey fails the converge at that step, before it can reach the env file.

## Debug channels: the harness journal, in a room

Each agent's `journalctl -u buzz-agent@<name>` is forwarded into a **private**
channel `debug-<name>`, so the owner can read what the harness is doing without
an SSH session. Two moving parts:

* `/usr/local/bin/buzz-agent-logger <name>` — follows the journal, strips ANSI,
  truncates lines at 800 chars, batches (`buzz_agent_log_flush_seconds`,
  `buzz_agent_log_max_lines`) and posts each batch as one fenced message.
* `buzz-agent-logger@<name>.service` — `Restart=on-failure`, so a relay outage
  or a `journalctl` death is survivable. `journalctl -f` follows the *journal*,
  not the process, so restarting an agent does not end the stream.

The forwarder posts as its **own** identity (`~devbox/.config/buzz-logs`,
kind:0 name `logs`, admitted to the relay like any agent) rather than as the
agent. That is deliberate: the relay refuses posts from non-members
(`restricted: not a channel member`), so the poster has to be in the channel —
and putting the *agent* in there would make it a participant in a room that is
just a log sink. The channel members are the forwarder and the owner (as
`owner`, so it can be renamed or deleted from the desktop without touching the
box). There is no feedback loop: the stream is `buzz-agent@%i`, the forwarder
runs as `buzz-agent-logger@%i`, so neither its own output nor the `buzz` send
is in what it forwards.

Message size is capped at 16000 bytes per batch because the relay rejects
content over 65536 (`content exceeds maximum size (N > 65536 bytes)`), and each
batch passes `--mention <self>`, which makes any bare `@word` in a log line
presentation-only so an unresolvable mention cannot get the batch rejected.

Channel ids are settled in `<agent dir>/debug_channel`; if that file is lost the
role finds the channel again by name (`buzz channels search --exact`) instead of
creating a second one.

## Live session internals: the NIP-AO observer stream

`BUZZ_ACP_RELAY_OBSERVER=true` (`buzz_agent_relay_observer`, upstream default
`false` — `crates/buzz-acp/src/config.rs:473-475`) makes buzz-acp publish
**kind 24200** frames: NIP-44-encrypted to the owner, ephemeral, never stored,
one frame per second max. That is the agent's actual thinking and tool traffic
(`agent_thought_chunk`, `agent_message_chunk`, `acp_read`, `acp_write`,
`turn_started`…), where `debug-<name>` is the coarse, persisted harness log.

The owner watches it in **Buzz Desktop**, no setting to turn on:

* while an agent is working, the composer shows a *"… is working"* pill →
  **Agents working** popover → click the agent (`BotActivityBar.tsx:161-250`);
* or from a member/profile popover, **"View activity log"**
  (`UserProfilePopover.tsx:439-447`) / **"View activity"** in the members
  sidebar;
* the panel header toggles between **Activity** and **Raw ACP activity**
  (`AgentSessionThreadPanel.tsx:249`).

The desktop only starts the subscription for a viewer who owns at least one
managed agent (`observerRelayStore.ts:656-660`).

**One deployment-specific catch.** The relay only accepts a 24200 frame from an
agent whose owner it already knows, via `users.agent_owner_pubkey`
(`handlers/event.rs:1007-1057` → `is_agent_owner`). It learns that column from
the NIP-OA tag on AUTH — but only in the *delegation* branch, and
`check_relay_membership` returns `Member` and short-circuits before it for a
pubkey that is already in `relay_members`, which every agent here is
(`crates/buzz-relay/src/api/mod.rs:74-80`). On a closed relay the column is
therefore never written and every frame is rejected with
`restricted: observer frame is not authorized for this agent owner`. The role
backfills exactly what that branch would have written (one `UPDATE` per agent,
only when the column is NULL, only when an attestation exists). The relay caches
the negative answer for five minutes, so after a first-time backfill the stream
can take that long to come alive.

## Introductions

The first time an agent is configured it opens a DM with the owner and posts
its name and pubkey (marker: `.intro_sent`). That is how the owner learns a new
agent exists and what to `add-member` into a channel. Keep `@` out of that text
— the relay rejects a message whose `@name` does not resolve to a member of the
channel.

## Auth

There is no `ANTHROPIC_API_KEY` here. `claude_code_oauth_token` (from
`claude setup-token`) is required and lands **only** in the 0600
`EnvironmentFile`. `claude-agent-acp` runs on `@anthropic-ai/claude-agent-sdk`,
which lists `CLAUDE_CODE_OAUTH_TOKEN` among its credential env vars and only
falls back to `~/.claude/.credentials.json` when neither it nor
`ANTHROPIC_API_KEY` is set.

`codex-acp` has **no** credential env var for a ChatGPT login: it drives the
Codex CLI, which reads `~/.codex/auth.json` (`auth_mode: chatgpt`, refresh
token inside). So `codex_auth_json` — the contents of that file from a machine
where you ran `codex login` — is written to `~devbox/.codex/auth.json` (0600,
dir 0700) with `force: no`: codex refreshes the access token in that file on the
box, and re-pushing the stashed copy would roll it back to an expired one.
(`OPENAI_API_KEY` also works if that is the credential you have; put it in the
env template instead.)

## Claude Code Remote Control: not available on this path

Remote Control (attach to a running Claude Code session from claude.ai/code or
the mobile app) **cannot be enabled** for the `claude` agent as deployed.
Verified against the packages installed on buzztest (2026-08-14):
`@agentclientprotocol/claude-agent-acp` 0.68.0 and its bundled
`@anthropic-ai/claude-agent-sdk`. Two independent blockers:

1. **The adapter never asks for it.** The SDK does expose the entry point —
   `enableRemoteControl(...)` on the object `query()` returns
   (`…/claude-agent-sdk/sdk.mjs:120`, undocumented: it is absent from
   `sdk.d.ts`) — and the bundled `claude` binary implements the matching
   `remote_control` control request for SDK-driven sessions (its bridge tags
   include `remote-control-sdk`). But the adapter never calls it: a grep for
   `enableRemoteControl|remote_control|remoteControl` over
   `claude-agent-acp/dist/` returns nothing. Its only injection surface is
   ACP `session/new` `_meta.claudeCode.options`
   (`dist/acp-agent.js:4628, 4683`), which buzz-acp does not send, and its own
   argv handling stops at `--cli`, `--version`, `--hide-claude-auth`
   (`dist/index.js:8, 38`). `BUZZ_ACP_AGENT_ARGS` does not help: buzz-acp
   normalizes args to zero for known adapters, and adapter args are not
   forwarded to the SDK's `claude` subprocess anyway. There is no
   remote-control env var — the `CLAUDE_CODE_*REMOTE*` family in the binary is
   about running *inside* Anthropic's cloud sandbox.
2. **The credential is inference-only.** This box authenticates with
   `CLAUDE_CODE_OAUTH_TOKEN` (`claude setup-token`), and the CLI refuses
   Remote Control for exactly that, verbatim from the binary: *"Remote Control
   requires a full-scope login token. Long-lived tokens (from `claude
   setup-token` or `CLAUDE_CODE_OAUTH_TOKEN`) are limited to inference-only for
   security reasons. Run `claude auth login` to use Remote Control."*
   Reproduced live: `su - devbox -c 'claude remote-control --help'` →
   *"You must be logged in to use Remote Control."*

`--remote-control [name]` / `--rc` exists on the CLI but is documented as
*"Start an **interactive** session with Remote Control enabled"*, and the
SDK-driven process here runs `--output-format stream-json --input-format
stream-json`.

**What would unblock it:** Zed's `claude-agent-acp` calling
`queryInstance.enableRemoteControl(...)` behind an ACP option and surfacing the
bridge session back over ACP, buzz-acp passing that option on `session/new`,
and Anthropic adding the method to the SDK's public types. Plus, on the box, an
interactive `claude auth login` as `devbox` replacing the long-lived token —
which is at odds with an unattended systemd service by design.

The nearest thing that works today is unrelated to the buzz agent: an
interactive `claude --remote-control` in a shell as `devbox` (still needing the
full-scope login) gives the owner a *separate* session to drive from the Code
tab of the Claude app. It does not attach to the agent sitting in the relay.
The **observer stream** above is the supported way to watch this agent live.

## Antigravity (agy): blocked on ACP

`agy` is installed on the box by `roles/devtools`, but it is deliberately **not**
in `buzz_agents`. What this role needs from an agent is an ACP server on stdio;
`agy` does not have one, and no sanctioned adapter provides one.

Verified on buzztest against agy **1.1.12** (2026-08-14):

* `agy --help` lists no `--acp` / `--experimental-acp`. Headless is print mode
  only: `-p/--print`, `--output-format text|json|stream-json`, `--json-schema`,
  `--mode`, `--dangerously-skip-permissions`. Request/response, not a session
  protocol.
* `agy plugin` does `import|install|enable|disable|validate` for gemini/claude
  style plugins — no transport or server hook. `agy plugin list` on the box:
  "No imported plugins".
* The 1.1.11/1.1.12 changelogs (`agy changelog`) never mention ACP, the Agent
  Client Protocol, or JSON-RPC stdio.
* Antigravity is not in the [ACP agent registry](https://agentclientprotocol.com/get-started/agents)
  (~39 agents, Gemini CLI among them), and not in buzz desktop's own
  `KNOWN_ACP_RUNTIMES` (goose, claude, codex, buzz-agent) or its preset
  harnesses (devin, cursor, omp, grok, opencode, kimi, amp, hermes, openclaw) —
  `desktop/src-tauri/src/managed_agents/discovery.rs`. `gemini-cli`'s
  `--experimental-acp` belongs to a different, deprecated binary that does not
  front Antigravity.

Third-party adapters exist — [`agy-acp`](https://github.com/shindgew/agy-acp)
(Apache-2.0, published 0.5.0, pushed 2026-08-13) is the maintained one;
`antigravity-acp` and `agy-acp-bridge` are stale. We are not using them, for two
independent reasons:

1. **Terms of Service.** Google's [FAQ](https://antigravity.google/docs/faq):
   *"Using third party software, tools, or services to access Antigravity is a
   violation of our Terms of Service … Such actions may be grounds for
   suspension or termination of your account."* Enforcement has already happened
   in the wild (the OpenClaw ban wave). The account at risk is the owner's.
   Google's own recommendation for third-party agents is a Vertex / AI Studio
   Gemini API key, which is a different product than Antigravity.
2. **It is a reverse-engineering wrapper.** `agy-acp` spawns `agy` in a PTY,
   treats its stdout as a diagnostic tail, and reads answers out of agy's
   private protobuf SQLite store under
   `~/.gemini/antigravity-cli/conversations/`. No forward-compatibility
   guarantee, and its open issue
   [#105](https://github.com/shindgew/agy-acp/issues/105) is a turn-hang on
   agy 1.1.12 — exactly the version we run.

**What unblocks this:** Google shipping a stdio JSON-RPC ACP mode in
antigravity-cli — the open request is
[antigravity-cli#31](https://github.com/google-antigravity/antigravity-cli/issues/31)
(no response yet) — and registering it on the ACP registry. Revisit then: a
built-in `agy acp` would still need a small role change first, because
`tasks/agent.yml` installs `agent.adapter_npm` unconditionally and an ACP-native
CLI has no npm adapter to install.

### The auth half already works

The other half of the question is settled, so nothing else has to be solved
later. `agy` demands an interactive sign-in on first use, but that sign-in
persists and a non-interactive process reuses it. **One manual step, once per
box:**

```bash
ssh root@<host>
su - devbox -c agy        # follow the browser device flow, then quit
```

It writes `~devbox/.gemini/antigravity-cli/antigravity-oauth-token` (0600) plus
`settings.json`, and after that a headless run works with no TTY and no
interaction — verified on buzztest:

```console
$ su - devbox -c 'agy -p "What is 6 times 7? Answer with the number only." --output-format json' < /dev/null
{"conversation_id":"bf716b00-…","status":"SUCCESS","response":"42\n","duration_seconds":2.16,…}
```

So a systemd unit under `devbox` would pick the credential up. Only the ACP
surface is missing.

## Who the agents listen to

`buzz-acp`'s author gate defaults to `owner-only`, and **an agent with no
resolved owner drops every inbound event silently**. So the role requires
`buzz_relay_owner_pubkey` (64-char hex, the same key as the relay's
`RELAY_OWNER_PUBKEY`) and passes it as `BUZZ_ACP_AGENT_OWNER`. Set
`buzz_agent_respond_to: allowlist` plus `buzz_agent_respond_to_allowlist` to
add teammates, or `anyone` to open it up. The setting is role-wide: all agents
share it.

## Variables

See `defaults/main.yml`. Required: `claude_code_oauth_token`,
`buzz_relay_owner_pubkey` (unless `buzz_agent_respond_to` is `anyone`/`nobody`).
Optional: `codex_auth_json`, `buzz_agents`, `buzz_agent_auth_tags` (without it
the app shows "owner unavailable" and the observer stream stays off),
`buzz_agent_relay_observer`, `buzz_agent_log_flush_seconds`,
`buzz_agent_log_max_lines`.

## Operating it

```bash
systemctl status 'buzz-agent@*' 'buzz-agent-logger@*'
journalctl -u buzz-agent@codex -f          # or just read #debug-codex
journalctl -u buzz-agent-logger@codex -f   # the forwarder itself
systemctl restart buzz-agent@claude
docker exec $(docker ps -q -f label=com.docker.compose.project=buzz-prod \
                          -f label=com.docker.compose.service=relay) \
  buzz-admin list-members
```

In a channel, `@`-mention the agent's pubkey. The owner can also send
`!cancel`, `!rotate` or `!shutdown` (the harness consumes them; systemd
restarts after `!shutdown`).
