# dotfiles

Configuration for two Macs that behave like one machine: an always-on Mac Mini
in the office, and a MacBook Air that travels.

Managed with [yadm](https://yadm.io), which is a thin wrapper around git whose
work tree is `$HOME`. The git directory lives at `~/.local/share/yadm/repo.git`,
so there is no `.git` in your home folder.

---

## The idea in one paragraph

Most "sync my two machines" setups try to mirror everything in both directions
and then spend the rest of their life resolving conflicts. This one doesn't.
The Mini is always on, so **the Mini is where work happens** — you SSH in from
the Air and attach to a long-running tmux session. Your editor, your shell, your
half-finished Claude Code conversation are all still running on the Mini exactly
as you left them. Nothing was copied anywhere, so there is nothing to reconcile.

Sync exists only for the case the Mini can't cover: the Air on a plane.

---

## The three layers

| Layer | Tool | Owns | Direction |
|---|---|---|---|
| 1. Network | Tailscale | Reaching the Mini from anywhere | — |
| 2. Continuity | tmux + mosh | Live work in progress | none — it never moves |
| 3. Fallback | yadm, git, Syncthing | Config, code, Claude state | two-way |

The important part is that **layer 2 does the real work**. Layers 1 and 3 exist
to support it. If you only ever worked at the Mini's monitor, you wouldn't need
layer 3 at all.

---

## Layer 1 — Tailscale

Both machines join a private mesh network. The Mini is reachable as `mini` from
anywhere with internet, with no port forwarding, no dynamic DNS, and no exposure
to the public internet.

**Tailscale SSH** is enabled, which means SSH authentication happens through your
tailnet identity rather than through key files. This is why no private key is
ever synced between machines — there's nothing to sync.

`~/.ssh/config.mini` adds keepalives so a tmux attach doesn't hang when the
network hiccups, and connection multiplexing so subsequent commands are instant.
It's wired into `~/.ssh/config` via an `Include` line that `bootstrap` adds.

---

## Layer 2 — How you actually work

From the Air (or the Mini itself), type:

```
mini
```

or hit `cmd+shift+m` in Ghostty. That's `bin/mini`, a plain bash script, which
for the bare form runs:

```
mosh mini -- tmux new -A -s main
```

Three things are happening:

- **`mosh`** instead of `ssh` — mosh survives your laptop lid closing, your IP
  changing when you move between wifi and cellular, and multi-hour suspends. An
  ssh session dies in all three cases. If mosh isn't installed, it falls back to
  `ssh -t`.
- **`tmux new -A -s main`** — `-A` means *attach if the session exists, create it
  if it doesn't*. So the first call of the day creates `main`; every call after
  that reattaches to the same one.
- **The session never dies.** `destroy-unattached off` in `.config/tmux/tmux.conf`
  means detaching (or your laptop dying) leaves everything running on the Mini.

The consequence worth internalising: **you never "move" work between machines.**
A build running on the Mini keeps running while you close the Air and drive home.
You sit down at the Mini's monitor, run `mini`, and you're looking at the same
session — same scrollback, same running processes.

---

## Layer 3 — Sync, and who owns what

This layer only matters when the Air is offline. The cardinal rule:

> **Exactly one tool owns any given file.** Two tools managing the same file
> means they overwrite each other in a loop.

### yadm owns declarative config

Things with a canonical, hand-edited version: shell config, editor settings,
`Brewfile`, the tmux config, `CLAUDE.md`, Claude `settings.json`, skills. You
commit these deliberately, and `yadm pull` on the other machine picks them up.

The repo is **public**, so anything secret must go through `yadm encrypt`, which
stores files encrypted inside the repo and unlocks them with a passphrase.

### git owns code

Repos under `~/projects` are normal git repos with normal remotes. Under the
remote-first model the Air's copies are read-mostly — you edit on the Mini — so
the Air mostly just needs to pull.

### Syncthing owns Claude's runtime state

`~/.claude` contains things you never hand-edit but very much want on both
machines: session transcripts, conversation history, todos. These are
append-mostly JSONL files that change constantly. Git would be a conflict
factory; Syncthing just mirrors them continuously.

`~/.claude/.stignore` draws the line:

| Synced | Ignored |
|---|---|
| `projects/` — session transcripts and memory | `cache/`, `paste-cache/`, `telemetry/` |
| `history.jsonl` | `shell-snapshots/`, `session-env/` |
| `todos/`, `tasks/` | `plugins/` — reinstallable, large, churny |
| `file-history/`, `backups/` | `daemon/`, `*.lock` |
| | `CLAUDE.md`, `settings.json`, `skills/` — **yadm owns these** |

That last row is the rule in action. Those files are in `~/.claude`, which is a
Syncthing folder, but yadm already manages them — so Syncthing is explicitly told
to keep its hands off.

Note that `.stignore` is itself **not synced** — Syncthing treats it as an
internal file. Both machines need their own copy, which is why it lives in yadm
rather than being propagated by Syncthing itself.

**Why session transcripts sync at all:** Claude Code keys its session directories
on the absolute working directory, so `~/projects/magpie` becomes
`-Users-ldan-projects-magpie`. Both machines use the username `ldan`, so those
paths match and a conversation started on one machine can be resumed on the
other. A different username on the Mini would silently break this — which is why
it's the single most important thing to get right during Setup Assistant.

---

## Preparing the Air to work with the Mini

Do these in order. The Mini must be set up first — it's the thing being
connected *to*. Run `mini doctor` after each step to see what's still outstanding.

### 1. Get the packages

```
yadm pull
brew bundle --file=~/Brewfile
```

This installs tmux, mosh, syncthing, atuin and Tailscale. Everything below
depends on it.

### 2. Run bootstrap

```
yadm bootstrap
```

On the Air, plain — **no `--server`**. You do not want a laptop that never
sleeps. This wires `~/.ssh/config.mini` into `~/.ssh/config`, starts Syncthing,
and offers to generate an SSH key for GitHub.

### 3. Join the tailnet

```
open -a Tailscale
```

Sign in with the same account as the Mini. Then confirm the Air can see it:

```
tailscale status
ssh mini true && echo reachable
```

MagicDNS is what makes the bare name `mini` resolve. If `ssh mini` fails but
`tailscale status` lists the machine, MagicDNS is off — enable it in the
Tailscale admin console under DNS.

### 4. Pair Syncthing

Open `http://127.0.0.1:8384` on both machines.

1. On the Mini: **Actions → Show ID**, copy the device ID.
2. On the Air: **Add Remote Device**, paste it, accept.
3. On the Air: **Add Folder**, settings below.
4. On the Mini: accept the shared folder, point it at `~/.claude`.

#### Order matters

> **`yadm clone` on the Mini before sharing the folder.**

`.stignore` is on Syncthing's internal-files list, alongside `.stfolder` and
`.stversions` — **it is not synced between devices.** Each machine needs its own
copy, which yadm provides. Share the folder before the Mini has one and it will
happily pull `plugins/`, `cache/`, and the yadm-owned config on first sync,
which is precisely what the ignore file exists to prevent.

Two more: add the folder on **one** device and accept the share on the other
(creating it independently on both produces mismatched folder IDs), and because
the Mini starts empty, **the Air is authoritative** — do this before real work
happens on the Mini, or first sync becomes a merge of two divergent transcript
sets and `history.jsonl` will conflict immediately.

#### Folder settings

**General**

| Field | Value |
|---|---|
| Folder Label | `Claude State` |
| Folder ID | `claude-state` — override the random default |
| Folder Path | `~/.claude` |

**File Versioning — the one that matters**

Set **Staggered**, max age **30** days. Session transcripts are not
reproducible: if a sync goes wrong there is no re-deriving them. Staggered keeps
one version per 30 seconds for the first hour, hourly for a day, daily for 30
days, then weekly. Versions go to `~/.claude/.stversions`, which is itself not
synced, so it costs disk on one machine only.

**Advanced**

| Setting | Value | Why |
|---|---|---|
| Folder Type | Send & Receive | Default. Correct — this is bidirectional |
| Watch for Changes | **On** | Default `true`; confirm it. Without it, changes wait for the hourly rescan |
| Watch Delay | `10`s | Default |
| Full Rescan Interval | `3600` | Default. Safety net behind the watcher |
| Ignore Permissions | Off | Same user on both machines |
| **Ignore Delete** | **Off** | Tempting as a safety net. Don't — stale files accumulate forever and genuine deletions stop propagating. Versioning is the correct net |
| Max Conflicts | `10` | Default. **Never 0** — `history.jsonl` conflicts occasionally, and 0 means one machine's writes disappear silently |

**Ignore Patterns tab** — this edits `.stignore` directly. It should already show
the 36 lines yadm installed. If it's blank, do not save: you would wipe the file.

#### Check the first sync before trusting it

If `~/.claude/plugins` or `~/.claude/cache` start appearing on the other machine,
the `.stignore` is not being read. Stop and fix that before it mirrors gigabytes.
`mini doctor` verifies the folder is shared, the watcher is on, and versioning is
configured.

### 5. Sync shell history

```
atuin register     # first machine only; use `atuin login` on the second
atuin sync
```

Optional, but it means the command you ran on the Mini this morning is in the
Air's history search this afternoon.

### 6. Verify the whole chain

```
mini doctor
```

Everything should be green. Then the real test:

```
mini
```

You should land in a tmux session on the Mini. Detach with `ctrl-a d`, run
`mini` again, and confirm you get the *same* session back — that round trip is
the entire model working.

---

## The `mini` command

Everything to do with the Mini is one command. It is **bash, not fish** — so it
works over ssh, in any shell, and on a machine that hasn't been configured yet.

| Command | Does |
|---|---|
| `mini` | Attach to the `main` session — the 95% case |
| `mini connect <name>` | Attach to, or create, a named session |
| `mini ls` | List sessions without attaching |
| `mini run <cmd>` | Run one command remotely and come straight back |
| `mini shell` | A plain login shell, no tmux |
| `mini status` | Fast health summary; non-zero exit if anything is wrong |
| `mini doctor` | Check every link and print the remedy for each failure |
| `mini preflight` | Prepare this machine to work offline |
| `mini help` | Usage |

`bin/mini` is a dispatcher; each subcommand is a file in `~/.local/lib/mini/`
defining a `mini_<name>` function. Adding a subcommand means adding a file.

Two behaviours worth knowing:

- **It knows which machine it's on.** On the Mini, `mini connect` attaches to a
  local tmux session rather than ssh-ing to itself, and `mini run` just runs the
  command. `doctor` checks the Mini for live sessions and iCloud eviction, and
  the Air for whether it can reach the Mini at all.
- **An unrecognised word is an error, not a session name.** `mini magpie` tells
  you to use `mini connect magpie` rather than silently creating a session named
  `magpie` from a typo.

`$MINI_HOST` overrides the target host, `$MINI_SESSION` the default session.

### mini doctor

Checks every link and prints the exact remedy for anything broken. Read-only and
safe to run at any time; exits non-zero if any check failed.

```
Packages
  ✗ tmux missing
      → brew bundle --file=~/Brewfile
Reaching the Mini
  ✗ cannot ssh to 'mini'
      → check Tailscale on both ends; is the Mini awake?
```

The check worth knowing about is **username match**. It compares `whoami` on
both machines and fails loudly if they differ, because that's the one
misconfiguration that breaks Claude session continuity silently — files sync
fine, they just land in a directory the other machine never reads.

### Tests

`.local/lib/mini/tests.sh` stubs ssh and mosh so the remote paths can be checked
without a reachable Mini — argument quoting, dispatch, and error handling.

```
bash ~/.local/lib/mini/tests.sh
```

## Before you go offline

```
mini preflight
```

It prepares the Air for working without the Mini:

1. **Fast-forwards every repo** under `~/projects`. It uses `--ff-only`, and it
   *skips* any repo with uncommitted changes or no remote rather than risking a
   conflict or a silent stash. It reports what it skipped.
2. **Triggers a Syncthing rescan** so `~/.claude` is current rather than waiting
   for the next scan interval.
3. **Pins the Obsidian vault** with `brctl download`. iCloud evicts files it
   thinks are cold and leaves behind a placeholder that fails to read when you're
   offline. This forces the real bytes local.

It exits non-zero if any pull failed, and never commits, pushes, or touches a
dirty tree.

---

## Setting up a new machine

One command on a fresh Mac:

```
curl -L 'https://raw.githubusercontent.com/danielyan/dotfiles/refs/heads/main/bin/mac-setup' | bash
```

That installs Homebrew and yadm, clones this repo over `$HOME`, and runs
`bootstrap`. Or do it by hand:

```
brew install yadm
yadm clone https://github.com/danielyan/dotfiles.git
yadm bootstrap            # a workstation, e.g. the Air
yadm bootstrap --server   # an always-on machine, e.g. the Mini
```

`bootstrap` is **idempotent** — every step checks the current state first, so
re-running it is safe and is the normal way to apply new Brewfile entries. It:

- installs Homebrew if missing, then `brew bundle` from the `Brewfile`
- registers fish in `/etc/shells` and makes it the default shell, if it isn't
- symlinks VSCode settings and installs extensions with `--force` so
  already-installed ones are a no-op instead of an error
- wires `~/.ssh/config.mini` into `~/.ssh/config`
- offers to generate an SSH key **for this machine** and add it to GitHub. Keys
  are deliberately per-machine so one can be revoked without affecting the other
- starts Syncthing and points you at `http://127.0.0.1:8384` to pair devices

`--server` additionally applies the always-on configuration:

```
sudo pmset -a sleep 0 disksleep 0 powernap 1 autorestart 1
```

— never sleep, and restart automatically after a power cut. It also pins the
vault. Screen Sharing and automatic login still have to be enabled by hand in
System Settings; there's no reliable scriptable equivalent.

---

## When something breaks

Start with `mini doctor` — it checks every link and names the fix. The cases below
are the ones it can't resolve for you.

**`mini` says it can't reach the host.** Check `tailscale status` on both ends.
If the Mini is up but unreachable it usually rebooted and hasn't logged in —
Screen Share in and check.

**A tmux session vanished.** `mini ls` lists what's actually running. Sessions
survive detach and network loss, but not a Mini reboot. That's what `autorestart`
plus a login item mitigates, not eliminates.

**Syncthing conflict files** (`*.sync-conflict-*`). This happens when Claude ran
on both machines at once — `history.jsonl` is append-only per machine and has no
merge semantics. Rare under remote-first. Keep the larger file, delete the other.

**`mini preflight` skipped a repo.** By design: it won't pull into a dirty tree.
Commit or stash, then re-run.

**Claude can't find an old session on the other machine.** Check that
`~/.claude/projects` has the matching `-Users-ldan-...` directory. If the path
component differs, the two machines have different usernames and transcripts will
never line up.

---

## Layout

```
.config/fish/            shell config, prompt, abbreviations
.config/fish/completions/ mini.fish — completions only, no logic
.config/tmux/            tmux.conf — long scrollback, detach-safe
.config/ghostty/         terminal config, cmd+shift+m keybind
.config/yadm/bootstrap   provisioning, idempotent, --server mode
.config/vscode/          settings + extension list
.claude/                 CLAUDE.md, settings.json, skills, .stignore
.ssh/config.mini         Mini host config (no key material)
bin/mini                 the one command: connect, doctor, preflight, ...
.local/lib/mini/         its subcommands, one file each, plus tests.sh
bin/mac-setup            one-liner bootstrap for a fresh Mac
bin/mac-defaults         macOS system defaults
Brewfile                 every package, declarative
```

Design notes, decisions, and remaining work live in the Obsidian vault at
`projects/project-machine-continuity.md`.
