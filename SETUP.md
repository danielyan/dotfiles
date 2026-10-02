# SETUP

Start-to-finish setup for the two-machine continuity system: an always-on Mac
Mini (server) and a MacBook Air (client). See `README.md` for *why* it's built
this way — this is only what to do.

Do the Mini completely before starting the Air. The Air's final step drives both
machines over ssh and will refuse to run if the Mini isn't ready.

---

## Before you start

**The Mini's username must be `ldan`.** Claude Code keys its session directories
on the absolute working directory (`~/projects/magpie` → `-Users-ldan-projects-magpie`).
A different username means transcripts sync fine but land in a directory the other
machine never reads — it fails silently. Set it in Setup Assistant; changing it
later is painful.

You'll need the same Apple ID on both machines (for the iCloud vault) and a
Tailscale account.

---

## 1 · Mini — the server

### 1.1 Setup Assistant

- Username **`ldan`**
- Same Apple ID
- System Settings → General → Storage → **turn off "Optimize Mac Storage"**
  (iCloud evicts cold files; a headless service reading a placeholder fails)

### 1.2 Provision

```sh
curl -L 'https://raw.githubusercontent.com/danielyan/dotfiles/refs/heads/main/bin/mac-setup' | bash -s -- --server
```

Installs Homebrew + yadm, clones the dotfiles over `$HOME`, marks the machine
as a server (`yadm config --add local.class server`) and runs `yadm bootstrap`,
which applies `pmset -a sleep 0 disksleep 0 powernap 1 autorestart 1` —
never sleep, restart after a power cut — and pins the iCloud vault locally.
The mark stays, so later plain `yadm bootstrap` runs keep the Mini a server.

Bootstrap will offer to generate an SSH key and register it with GitHub. Accept.
Keys are per-machine so either can be revoked independently.

If `gh` lacks the `admin:public_key` scope it will offer to request it. Should
anything still fail, bootstrap exits non-zero and reprints the outstanding steps
with the exact commands — re-running `yadm bootstrap` retries them.

**Open a new terminal afterwards.** Bootstrap switches the default shell to fish
and puts `~/bin` on the path; the shell that ran the installer has neither.

### 1.3 Tailscale

The Mini runs the `tailscale` formula, not the app: the Brewfile picks it for a
machine of class `server`, and bootstrap starts its `tailscaled` as a system
service (`sudo brew services start tailscale`). As root it is a LaunchDaemon,
up before anyone logs in, so after a reboot the Mini is reachable without one.
The app, or `brew services` without sudo, would wait for a login.

If the app is still installed from before, remove it: `brew uninstall --cask
tailscale-app`. Two clients on one machine fight over the network.

### 1.4 Sign in and enable SSH

Either works. Tailscale SSH avoids managing keys:

```sh
sudo tailscale up --ssh    # prints a login URL; open it in any browser
```

> **Check your tailnet's SSH ACL.** New tailnets default to `"action": "check"`,
> which forces a browser re-auth every 12 hours. That breaks `dev run`,
> `dev pair`, and `dev doctor`, all of which use non-interactive ssh. In the
> admin console, change the `ssh` rule for your own devices to `"action": "accept"`.

Or skip Tailscale SSH and use plain sshd: System Settings → General → Sharing →
**Remote Login on**, then from the Air later, `ssh-copy-id mini`.

### 1.5 Remaining GUI toggles

No reliable CLI equivalent:

- System Settings → General → Sharing → **Screen Sharing on**
- System Settings → Users & Groups → **Automatic login → ldan**
  (so it recovers unattended after a reboot)

### 1.6 Verify

```sh
dev doctor
```

Expect green on packages, Tailscale, server role, and vault. Syncthing checks
will fail until step 3 — that's correct.

Start a session so there's something to attach to:

```sh
dev
```

---

## 2 · Air — the client

### 2.1 Provision

The Air already has yadm, so just update and provision:

```sh
yadm pull
brew bundle --file=~/Brewfile
yadm bootstrap
```

Plain bootstrap — **no `--server`**. You don't want a laptop that never sleeps.
(On a *fresh* laptop, use the same one-liner as 1.2 without `-s -- --server`.)

### 2.2 Tailscale

```sh
open -a Tailscale
```

Same account as the Mini.

### 2.3 Verify reachability

```sh
/Applications/Tailscale.app/Contents/MacOS/Tailscale status
ssh mini true && echo reachable
```

If `tailscale status` lists the Mini but ssh fails, MagicDNS is off — enable it
in the admin console under DNS. If ssh prompts for a password, you're on plain
sshd: run `ssh-copy-id mini`.

---

## 3 · Connect them

### 3.1 Syncthing

From the **Air**:

```sh
dev pair
```

Reads both device IDs over ssh, introduces the machines, creates the
`claude-state` folder on both ends with staggered versioning (30 days),
filesystem watching, and `maxConflicts: 10`. Idempotent.

It refuses to run unless `~/.claude/.stignore` exists on both machines.
Syncthing does **not** sync that file — each machine needs its own copy from
yadm, which step 1.2 provides. Without it, first sync would pull `plugins/` and
`cache/`.

**Watch the first sync** at `http://127.0.0.1:8384`. If `plugins/` or `cache/`
appear on the far end, stop — the ignore file isn't being read.

Because the Mini starts empty, the Air is authoritative. Pair before doing real
work on the Mini, or first sync merges two divergent transcript sets and
`history.jsonl` conflicts immediately.

### 3.2 Shell history

Optional, but this is the order — and atuin's own database is separate from
fish's, so importing comes first or you sync an empty account.

On the **Air** (which has the history):

```sh
atuin import auto              # fish history → atuin's database
atuin register -u <user> -e <email>
atuin sync
atuin key                      # SAVE THIS
```

> `atuin key` prints your encryption key. History is encrypted client-side, so
> **the key is the only way to decrypt it on another machine** — the password
> alone is not enough, and there is no recovery if you lose it. Put it in
> Bitwarden now.

On the **Mini** (new, no history worth keeping):

```sh
atuin login -u <user> -k <key>
atuin sync
```

`login` takes the key; `register` generates one. Don't run `import` on the Mini
— there's nothing there worth importing, and sync will populate it.

### 3.3 Verify end to end

```sh
dev doctor         # everything green
```

Then the real test:

```sh
dev               # lands in tmux on the Mini
# ctrl-a d to detach
dev               # same session back
```

That round trip is the whole model working. `doctor` also compares `whoami` on
both machines and fails loudly on a mismatch — the silent killer from the top of
this doc.

---

## Daily use

| | |
|---|---|
| `dev` | This folder's session if it is running, else `main` |
| `dev <name>` | That session; offers to start it if it is missing |
| `dev connect` | Pick a session from a filterable list |
| `dev ls` | What's running, without attaching |
| `dev run <cmd>` | One command remotely |
| `dev status` | Fast health check |
| `dev preflight` | Before going offline: pull everything down |
| `dev land` | After coming back: push up, catch the Mini up |

Full command reference and troubleshooting: `README.md`.
