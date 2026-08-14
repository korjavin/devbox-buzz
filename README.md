# buzzbox

One command turns a cloud VM into a [Buzz](https://github.com/block/buzz) relay you own, with Claude and Codex agents already sitting in it.

**Read [Threat model](#threat-model) before you deploy.** This box is deliberately unsafe by design.

---

## What buzz is

Buzz is a workspace where humans and agents share the same rooms — and it is a **Nostr relay**: every message,
reaction, patch and workflow step is a signed event in one log.

Identity is a **keypair**, for people and for agents alike: a 64-hex private key you keep, a 64-hex public key
(also shown as `npub…`) everyone sees. There are no passwords, no OIDC, no SSO, no Slack. You do not "create an
account" — you show up with a key and sign.

Your relay is **closed**: it serves the owner pubkey and whoever the owner admits. Everyone else is refused at
the door, which is what makes a single-VM relay a private workspace rather than a public bulletin board.

---

## Quickstart

You need: `terraform`, `ansible`, `kv` (the [stash](https://github.com/umputun/stash) CLI on *your* machine —
nothing is stashed on the box), a domain on Cloudflare, and a Hetzner or DigitalOcean token.

**1. Put the credentials in stash:**

| Key | What |
|---|---|
| `secrets/hcloud-token` | Hetzner API token (or `secrets/do-token` with `DEVBOX_PROVIDER=digitalocean`) |
| `secrets/cf-dns-token` | Cloudflare token, DNS:Edit on the zone |
| `secrets/devbox-base-domain` | e.g. `dev.example.com` → box `foo` becomes `foo.dev.example.com` |
| `secrets/acme-email` | Let's Encrypt contact |
| `secrets/claude-code-oauth-token` | `claude setup-token` output. Omit it and you get a relay with no built-in agent |
| `secrets/codex-auth-json` | Contents of `~/.codex/auth.json` after `codex login`. Omit it and the codex agent starts but cannot authenticate |
| `secrets/buzz-owner-pubkey` | **Auto-generated on first `up`** — your identity, reused by every box |
| `secrets/buzz-owner-nsec-hex` | The private half of the above. **Back this up.** Lose it, lose your relays |

**2. Build the box:**

```bash
bin/devbox up mybox        # server + firewall + DNS + provisioning + health check
bin/devbox check mybox     # re-run the checks
bin/devbox down mybox      # destroy server, firewall, DNS (and all relay history)
bin/devbox list            # boxes this state directory knows about
```

`up` is idempotent — re-run it to converge. State is one terraform workspace per box.

**Certificates are always production Let's Encrypt.** Staging is not an option: the buzz-acp agent binary ships
rustls with compiled-in webpki roots and rejects staging certs (`UnknownIssuer`), ignoring the system trust store.
Production issues only 5 duplicate certs per week per hostname and every rebuild burns one — when iterating on
rebuilds, **vary the box name** instead of re-upping the same one all day.

**3. Connect:** install the [Buzz desktop app](https://github.com/block/buzz/releases/latest), point it at
`wss://mybox.dev.example.com`, and sign in with your owner key (`kv get secrets/buzz-owner-nsec-hex`; if the app
insists on `nsec1…`, convert the hex with any Nostr key tool). You are the relay owner, so you are already admitted.

---

## Connect your agents

### The built-in agents

`devbox up` deploys **two** agents as systemd services on the box — `claude` and `codex`. They work like
teammates, not bots:

```
you @mention one in a channel  →  buzz-acp  →  claude-agent-acp  →  Claude Code
                                     ↑         codex-acp        →  Codex
                                     └────── buzz-cli posts the reply ──┘
```

Each holds its **own** keypair (generated on the box, kept `0600` under the devbox user), authenticates to the
relay with it, and was admitted to the closed relay as a member — see
[`ansible/roles/buzz_agent`](ansible/roles/buzz_agent) for the exact admission call. Credentials come from your
stash: `claude-code-oauth-token` lands in a `0600` environment file, `codex-auth-json` in `~/.codex/auth.json`
(codex has no env-var path for a ChatGPT login).

**The first time an agent appears it DMs you** with its name and pubkey, so you always know who is on the box
and what to add to a channel.

```bash
ssh root@mybox.dev.example.com
systemctl status 'buzz-agent@*'   # are they alive
journalctl -u buzz-agent@codex -f # what is one doing
systemctl restart buzz-agent@claude
```

If an agent goes quiet, it is almost always the credential: check `journalctl` first, then re-run
`devbox up mybox` after refreshing the stashed token.

### Watching an agent work

Two views, both in the app:

* **`#debug-claude` / `#debug-codex`** — private channels, one per agent, carrying that agent's systemd
  journal, batched and posted by a small forwarder on the box. This is the persisted, coarse view: startup
  banners, reconnects, errors. The agent itself is *not* a member — the channel is a log sink, not a room it
  works in.
* **Live session internals** — the harness publishes NIP-AO observer frames (encrypted to your key, ephemeral):
  the agent's thinking, its tool calls, its ACP traffic. Click the *"… is working"* pill above the composer, or
  **View activity log** on the agent's profile, and toggle **Raw ACP activity** in the panel header.

### Telling the app who owns your agents

Buzz Desktop labels an agent message with its owner, and shows **"owner unavailable"** when the agent carries no
proof of one. That proof is a NIP-OA `auth` tag on the agent's profile event, and it is **signed by your key** —
which is exactly why the box cannot make it: your key never goes there. Mint one per agent on your own machine
and pass them in:

```bash
# on YOUR machine, from a checkout of block/buzz
cargo run -p buzz-sdk --release --example compute_auth_tag -- \
  "$(kv get secrets/buzz-owner-nsec-hex)" <agent_pubkey_hex> ""
# -> ["auth","<owner_hex>","","<sig_hex>"]
```

Agent pubkeys come from the intro DM (or `~devbox/.config/buzz-agent-<name>/public_key`). Feed the tags to the
role as `buzz_agent_auth_tags`, e.g.
`-e '{"buzz_agent_auth_tags":{"claude":"[\"auth\",...]","codex":"[\"auth\",...]"}}'`.

**It is off by default, because today it costs you the @mention picker.** The same tag that produces the owner
label is what makes the desktop classify the author as an agent, and the picker hides agents that are not in its
managed-agent list or the relay's kind:10100 directory — which a self-hosted agent is not. Turning it on trades
the label for the autocomplete entry in channels where the agent is a plain member. Both sides of the trade,
with citations, and the one-variable rollback:
[role README](ansible/roles/buzz_agent/README.md#owner-attribution-the-apps-owner-unavailable).

**Claude Code's Remote Control does not work for the on-box agent** — the ACP adapter never asks the SDK for it,
and a `claude setup-token` credential is inference-only, which Remote Control rejects. The observer stream above
is the supported way to watch this agent live; citations are in the
[role README](ansible/roles/buzz_agent/README.md#claude-code-remote-control-not-available-on-this-path).

Want a third brain (goose, or your own)? Add one line to `buzz_agents` in
[`ansible/roles/buzz_agent/defaults/main.yml`](ansible/roles/buzz_agent/defaults/main.yml) — name, npm package,
adapter binary — and re-run `devbox up`. Existing agents keep their identities.

**Antigravity (`agy`) is not one of them — not yet.** The box installs the CLI, but it cannot join the relay,
for one reason: an agent here has to speak [ACP](https://agentclientprotocol.com) over stdio, and `agy` has no
ACP surface. As of 1.1.12 its flags stop at headless print mode (`-p`, `--output-format json|stream-json`);
there is no `--acp`, its plugin system has no transport hook, and Antigravity is absent from the
[ACP agent registry](https://agentclientprotocol.com/get-started/agents) that lists ~39 agents including Gemini
CLI. Third-party adapters do exist on npm ([`agy-acp`](https://www.npmjs.com/package/agy-acp) is the maintained
one) but they drive `agy` by scraping a PTY and reading its private SQLite conversation store, and Google's
[FAQ](https://antigravity.google/docs/faq) is explicit: *"Using third party software, tools, or services to
access Antigravity is a violation of our Terms of Service … Such actions may be grounds for suspension or
termination of your account."* That has been enforced. So the sanctioned answer is to wait for Google to ship
an ACP mode ([antigravity-cli#31](https://github.com/google-antigravity/antigravity-cli/issues/31) is the open
request). The other half of the problem is already solved — one interactive `agy` sign-in on the box persists a
token that headless runs reuse — so when an ACP mode lands this is a small change, not a project. Details and
citations in the role [README](ansible/roles/buzz_agent/README.md#antigravity-agy-blocked-on-acp).

### Add another agent, from any machine

Any machine that can reach `wss://<host>` can host an agent — your laptop, a build box, another VPS. Three steps:

```bash
# 1+2 run on the box: buzz-admin lives inside the relay container, next to the DB and relay key
ssh root@mybox.dev.example.com

# 1. Mint the agent its own identity — save the secret key NOW, it is never shown again
docker exec buzz-prod-relay-1 buzz-admin generate-key

# 2. Admit it to your closed relay (writes the member row and publishes the NIP-43 roster)
docker exec buzz-prod-relay-1 buzz-admin add-member --pubkey <agent pubkey> --role member

# 3. Run the harness wherever you like — laptop, build box, another VPS.
#    buzz-acp ships as a static binary in block/buzz's "sprig" release (also provides the buzz CLI):
curl -fsSLO https://github.com/block/buzz/releases/download/sprig-latest/sprig-x86_64-unknown-linux-musl.tar.gz
tar xzf sprig-x86_64-unknown-linux-musl.tar.gz && ln -sf sprig buzz-acp && ln -sf sprig buzz
npm install -g @agentclientprotocol/claude-agent-acp
export BUZZ_PRIVATE_KEY="<agent secret key>"
export BUZZ_RELAY_URL="wss://mybox.dev.example.com"
export BUZZ_ACP_AGENT_COMMAND="claude-agent-acp"
export CLAUDE_CODE_OAUTH_TOKEN="<your claude setup-token>"
buzz-acp
```

`buzz-admin` and `buzz-acp` are installed on the box by the `buzz_agent` role — check
[`ansible/roles/buzz_agent`](ansible/roles/buzz_agent) for their paths and for how the built-in agent was
admitted, since that role is the authority on both.

Then add the agent to the channel and @mention it. Relay membership alone is not enough — every channel keeps
its own member list, and a mention of a non-member is rejected with the exact command to run:

```bash
buzz channels add-member --channel <channel uuid> --pubkey <agent pubkey> --role bot
```

Every agent needs its **own** keypair — never share one.
Swap `BUZZ_ACP_AGENT_COMMAND` for `codex-acp` or `goose` to attach a different brain.

### Run agents from the app on your own machine

The desktop app can also run a harness **locally** — it spawns the process on your own Mac instead of on the
box. Settings → Agents shows one row per harness, and **"Adapter needed"** means the CLI is installed but
the ACP adapter beside it is not:

| Row | CLI it looks for | Adapter binary | npm package |
|---|---|---|---|
| Claude Code | `claude` | `claude-agent-acp` (or `claude-code-acp`) | `@agentclientprotocol/claude-agent-acp` |
| Codex | `codex` | `codex-acp`, **1.1.7 or newer** | `@agentclientprotocol/codex-acp` |

The row's own **Install** button is the supported path and needs nothing installed first: the app downloads
a private Node.js into `~/Library/Application Support/Buzz/runtimes/node/` and installs the adapter into
`~/Library/Application Support/Buzz/node-tools/`, its own npm prefix — your system npm is never touched.
There is no cancel button, the per-command ceiling is 15 minutes, and a second Install for the same row is
refused while one is in flight, so a **spinner that has been up a while is usually still downloading**, not
wedged. Restarting the app clears it.

Installing the adapters yourself is one command, and it does not conflict — the app checks its own private
prefix first and keeps using its copy when both exist:

```bash
npm install -g @agentclientprotocol/claude-agent-acp @agentclientprotocol/codex-acp
```

Then hit **Check again**. If the row still says "Adapter needed", your npm prefix is somewhere the app does
not look. It probes its private prefix, then `$PATH`, then `command -v` in a **login** shell (`~/.zprofile`
and `~/.zshenv` — *not* `~/.zshrc`), then `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `~/.local/bin`,
`~/.volta/bin`, `~/.asdf/shims`, `~/.bun/bin`, `~/.local/share/mise/shims`, and finally nvm's `default`
alias. Compare that list against `npm prefix -g`, and export the fix from `~/.zprofile` — a `PATH` set only
in `~/.zshrc` is invisible to a GUI app.

("Update needed" on Codex is the old `@zed-industries/codex-acp` 0.16.x; Install replaces it.)

The catalog and detection order are in
[`desktop/src-tauri/src/managed_agents/discovery.rs`](https://github.com/block/buzz/blob/main/desktop/src-tauri/src/managed_agents/discovery.rs)
(`KNOWN_ACP_RUNTIMES`, `resolve_command`) in [block/buzz](https://github.com/block/buzz).

### Native git against the relay

Your relay is also a git host. `git clone`/`push` work over plain HTTPS with **no password and no SSH key** —
the credential helper signs each request with your Nostr key ([NIP-98](https://github.com/nostr-protocol/nips/blob/master/98.md)),
and the ACL is membership in the channel the repo is bound to:

```bash
buzz repos create --id myrepo --channel <channel uuid>   # announce + bind; unbound repos 404 for everyone
```

Repo URLs are `https://<host>/git/<owner pubkey hex>/<repo id>` — the **owner's** pubkey, not yours.

The box already has all of this (`ansible/roles/devtools`). On your own machine:

```bash
# 1. git >= 2.46 — the helper needs the credential protocol's `authtype` capability.
#    Ubuntu <= 24.04 ships 2.43: sudo add-apt-repository ppa:git-core/ppa && sudo apt install git
git version

# 2. The helper. Cargo-only upstream; with no Rust toolchain, build it in a container like the box does:
docker run --rm -v "$PWD:/out" rust:1-slim \
  cargo install --git https://github.com/block/buzz --locked --root /out git-credential-nostr
install -m 0755 bin/git-credential-nostr ~/.local/bin/

# 3. Point git at it. useHttpPath is required — the helper builds the NIP-98 `u` tag from the repo path.
git config --global credential.helper nostr
git config --global credential.useHttpPath true

# 4. Your key: $NOSTR_PRIVATE_KEY (hex or nsec1) wins over the `nostr.keyfile` config.
export NOSTR_PRIVATE_KEY=$(kv get secrets/buzz-owner-nsec-hex)
git clone https://mybox.dev.example.com/git/<owner pubkey>/myrepo
```

The agents get step 4 for free: `NOSTR_PRIVATE_KEY` is in their environment file alongside `BUZZ_PRIVATE_KEY`,
so each agent pushes as **itself** — its own key, its own channel memberships, its own commits. Nothing is
shared, and an agent can only reach the repos whose channel it was added to.

---

## Threat model

This is a **single-tenant personal workspace**. It is not hardened, not multi-tenant, and not trying to be.

The agent on the box runs Claude Code with your OAuth token, as a member of the `docker` group — which is
root-equivalent — on a host that also holds the relay's private key and every secret in `/opt/buzz/.env`.
**Anyone who can @mention the agent can steer it**, so a prompt injection (a fetched page, a dependency README,
a pasted issue body) reaches the same blast radius as the account itself. The closed relay is what keeps that
list of people short: admission is the security boundary, so admit deliberately and revoke by removing membership.

Also true, and worth knowing: your owner private key is the only credential — there is no reset, no recovery,
no support desk. SSH is open to the internet by default (`allowed_ssh_cidrs` narrows it). Docker images and npm
packages are trusted upstreams, and a compromise of any of them is root on the box.

That is a defensible trade for a box whose owner understands it. If you did not consciously opt into it, this
repo is not for you.

---

## What's where

```
bin/devbox            up / down / check / list — the whole lifecycle
terraform/            server + firewall (Hetzner or DigitalOcean modules)
ansible/playbook.yml  toolchain + relay + agent, one pass
ansible/roles/        system, docker, devtools, user_dotfiles, buzz, buzz_agent
stacks/buzz/          vendored upstream compose bundle (relay, Postgres, Redis, MinIO, Caddy)
```

`bin/devbox` passes these into ansible: `devbox_user`, `acme_email`, `buzz_host`, `buzz_owner_pubkey`,
`claude_code_oauth_token`.

**Backups.** Three things are not recreatable:

- `secrets/buzz-owner-nsec-hex` in your local stash — your identity.
- `/opt/buzz/.env` on the box — the relay's own key plus every database secret. A new relay key means clients
  see a different relay.
- The `buzz-postgres-data` and `buzz-minio-data` docker volumes — all message history and uploaded media.

`devbox down` destroys the server, so it destroys all three of the on-box items. Copy them off first if you care.

---

## Secrets on the box

The box runs [stash](https://github.com/umputun/stash) (`stacks/stash/`, deployed by `ansible/roles/stash` to
`/opt/stash`), bound to `127.0.0.1:8080` and nothing else — no Caddy route, no firewall hole. The loopback bind
*is* the access control. `bin/kv` is the CLI in front of it, installed to `~/.local/bin/kv`, so agents running on
the box can read secrets you put there instead of you baking them into env files:

```bash
kv set secrets/some-api-key "sk-..."   # or: echo -n "$V" | kv set secrets/some-api-key
kv get secrets/some-api-key
kv ls secrets/                         # list keys under a prefix
kv del secrets/some-api-key
```

This is separate from the *local* stash on your own machine that `bin/devbox` reads provisioning credentials
from (see [Quickstart](#quickstart)) — same tool, different host, different contents.

**Back up `/opt/stash/.env`.** It holds `STASH_SECRETS_KEY`, which encrypts everything in the `stash_data`
volume. Ansible settles that key rather than regenerating it, so re-running the playbook is safe — but lose the
file and every stored secret is gone, unrecoverably. `devbox down` destroys it along with the server.
