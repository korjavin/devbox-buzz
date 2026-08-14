# buzzbox

One command turns a cloud VM into a [Buzz](https://github.com/block/buzz) relay you own, with a Claude agent already sitting in it.

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

### The built-in Claude agent

`devbox up` deploys one agent as a systemd service on the box. It works like a teammate, not a bot:

```
you @mention it in a channel  →  buzz-acp  →  claude-agent-acp  →  Claude Code
                                    ↑                                  │
                                    └────── buzz-cli posts the reply ──┘
```

`buzz-acp` holds the agent's **own** keypair (generated on the box, kept `0600` under the devbox user), authenticates
to the relay with it, and was admitted to the closed relay as a member — see
[`ansible/roles/buzz_agent`](ansible/roles/buzz_agent) for the exact admission call. Its Claude credential is the
`claude-code-oauth-token` you stashed; the ansible role writes it into a `0600` environment file.

```bash
ssh root@mybox.dev.example.com
systemctl status buzz-agent      # is it alive
journalctl -u buzz-agent -f      # what is it doing
systemctl restart buzz-agent     # turn it off and on again
```

If the agent goes quiet, it is almost always the token: check `journalctl` first, then re-run `devbox up mybox`
after refreshing `secrets/claude-code-oauth-token`.

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
