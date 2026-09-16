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

## Setting it up

Step-by-step for both machines is in **`SETUP.md`**. The two constraints that
setup depends on, and the reasons behind them:

**The Mini's username must be `ldan`.** Session directories are keyed on the
absolute working directory. A mismatch syncs files fine but lands them where the
other machine never looks — silent failure.

**`.stignore` is not synced.** Syncthing treats it as an internal file, so each
machine needs its own copy from yadm. That makes ordering load-bearing:
`yadm clone` on the Mini *before* pairing, or first sync pulls `plugins/` and
`cache/` precisely because the ignore file isn't there yet. `mini pair` enforces
this rather than trusting you to remember.

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
| `mini pair` | Wire Syncthing to the Mini, both ends, idempotently |
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

## bootstrap

`.config/yadm/bootstrap` provisions a machine and is **idempotent** — every step
checks current state first, so re-running is safe and is the normal way to apply
new Brewfile entries.

```
yadm bootstrap            # a workstation, e.g. the Air
yadm bootstrap --server   # an always-on machine, e.g. the Mini
```

It installs Homebrew if missing then runs `brew bundle`, makes fish the default
shell, symlinks VSCode settings and installs extensions with `--force` so
already-installed ones are a no-op, wires `~/.ssh/config.mini` into
`~/.ssh/config`, offers to generate a **per-machine** SSH key for GitHub, and
starts Syncthing.

`--server` additionally applies `pmset -a sleep 0 disksleep 0 powernap 1
autorestart 1` — never sleep, restart after a power cut — and pins the vault.
Screen Sharing and automatic login have no reliable scriptable equivalent and
stay manual.

Pairing is deliberately *not* in bootstrap: it needs the far end reachable over
ssh, which bootstrap can't guarantee. That's `mini pair`, run later.

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
SETUP.md                 start-to-finish setup for both machines
bin/mac-defaults         macOS system defaults
Brewfile                 every package, declarative
```

Setup instructions: `SETUP.md`. Design notes, decisions, and remaining work
live in the Obsidian vault at `projects/project-machine-continuity.md`.
