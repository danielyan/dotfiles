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

Installs Homebrew + yadm, clones the dotfiles over `$HOME`, runs
`yadm bootstrap --server`, which applies `pmset -a sleep 0 disksleep 0 powernap 1 autorestart 1` —
never sleep, restart after a power cut — and pins the iCloud vault locally.

Bootstrap will offer to generate an SSH key and add it to GitHub. Accept. Keys
are per-machine so either can be revoked independently.

**Open a new terminal afterwards.** Bootstrap switches the default shell to fish
and puts `~/bin` on the path; the shell that ran the installer has neither.

### 1.3 Tailscale

```sh
open -a Tailscale
```

Sign in. Interactive login is correct here — don't bother with auth keys for a
Mac with a browser attached.

### 1.4 Enable SSH

Either works. Tailscale SSH avoids managing keys:

```sh
# The cask does not put the CLI on $PATH; it lives inside the app bundle.
/Applications/Tailscale.app/Contents/MacOS/Tailscale up --ssh
```

> **Check your tailnet's SSH ACL.** New tailnets default to `"action": "check"`,
> which forces a browser re-auth every 12 hours. That breaks `mini run`,
> `mini pair`, and `mini doctor`, all of which use non-interactive ssh. In the
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
mini doctor
```

Expect green on packages, Tailscale, server role, and vault. Syncthing checks
will fail until step 3 — that's correct.

Start a session so there's something to attach to:

```sh
mini connect
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
mini pair
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

```sh
atuin register     # first machine; use `atuin login` on the second
atuin sync
```

Optional.

### 3.3 Verify end to end

```sh
mini doctor        # everything green
```

Then the real test:

```sh
mini              # lands in tmux on the Mini
# ctrl-a d to detach
mini              # same session back
```

That round trip is the whole model working. `doctor` also compares `whoami` on
both machines and fails loudly on a mismatch — the silent killer from the top of
this doc.

---

## Daily use

| | |
|---|---|
| `mini` | Attach to the `main` session |
| `mini ls` | What's running, without attaching |
| `mini run <cmd>` | One command remotely |
| `mini status` | Fast health check |
| `mini preflight` | Before going offline: pull all repos, rescan, pin vault |

Full command reference and troubleshooting: `README.md`.
