# cloudmule

cloudmule runs the heavy work of the user's projects (dependency installs, builds, tests, dev servers, test
browsers, renders) on ONE Hetzner Cloud server rented by the hour and shared by all their projects. Their
computer only edits. The cycle: **create or join the server → upload only what changed → run jobs → download
results → release the lease → when nobody uses it: snapshot and DELETE the server.**

Talk to the user in their language. This file is for agents; humans read `README.md`.

## Installing cloudmule (when the user asks for it in this folder)

Do it step by step, explaining each one in plain words, and stop at anything that fails.

1. **Requirements.** Check `bash --version` (Windows: Git Bash), `python3 --version` or `python --version`,
   `ssh -V`, `hcloud version`. If `hcloud` (Hetzner's official CLI) is missing, offer to install it, with the
   user's permission: Windows `winget install --id HetznerCloud.CLI --exact --source winget`, macOS
   `brew install hcloud`, Linux: the release binary from github.com/hetznercloud/cli, verifying its SHA256
   against the release's `checksums.txt`.
2. **Hetzner account and token.** If the user has none: create an account at hetzner.com/cloud, create a
   project (a dedicated one for cloudmule is best), then Security → API tokens → Generate, **Read & Write**.
   Then `cp .env.example .env` and ask the user to paste the token into `.env` **themselves**. Never ask for it in
   the chat, never print it.
3. `bash bin/cloudmule setup`: checks the token, shows prices, creates this computer's SSH key and registers it
   in Hetzner, saves this folder's location in `~/.config/cloudmule/home` and installs the Claude Code plugin
   (the `cloudmule` skill). Tell the user the skill appears in **new** Claude Code sessions.
4. Done. Explain the next step: in any project, ask for heavy work ("run the tests") or say "set up cloudmule
   here". There is no image to build: the first `start` installs what each project needs (it takes a few
   minutes longer, once).

## Rules (mandatory)

- **Spending money needs the user's choice and confirmation.** Before `start` or `oneshot` creates a server,
  show the user the options from `servers <project>` (free), recommend one, and wait for their choice; then
  `start … --type <chosen>`. Joining a running server needs no new choice. With a session open, `sync`, `job`,
  `attach`, `pull`, `run` and `tunnel` need no new confirmation; neither do `servers`, `status`, `leases`,
  `projects`, `init`, `setup`, `end` and `start --dry-run`.
- **Report the server type and price** used (the "Creating … EUR/h" line).
- **When done: `end <project> [target] --keep`, then `status`.** `end` releases your project's lease and only
  deletes the server if no other project holds one. Don't leave leases behind "just in case".
- **Other sessions share the server** (other projects, other Claude sessions, other computers of the same user).
  Never delete it while other leases exist:
  1. `leases` shows each lease (project, target, computer, minutes since last use) and the running jobs.
  2. If `end` answers `OTHER_PROJECTS_USING_THE_SERVER`, leave the server on and tell the user.
  3. A lease that looks abandoned (long unused, 0 jobs running): ask the user (or that project's session)
     before `end … --force`.
  4. Don't worry about forgotten leases: with no activity the guard snapshots and deletes the server after
     `IDLE_MINUTES` (45). Forcing only saves that wait.
  5. When `start` shows other projects' leases, tell the user they share CPU and RAM.
- **Token:** only in `.env` (`HCLOUD_TOKEN`), pasted by the user. Never print it, never use `set -x`. On the
  server it lives only in `/run/cloudmule/token` (RAM), so it never ends up in a snapshot.
- **Never put secrets in a project's `.cloudmule/`**: it may be committed, even to a public repository.
  cloudmule refuses to run if it finds files that look like secrets there.
- **Don't restart on your own** a job the system or the user stopped. Report it and ask.
- **Before uploading a user's project for the first time**, remind them it will be stored on a third-party
  server (Hetzner) and in snapshots in their account.
- **Only Hetzner's official `hcloud` CLI.** No community MCP servers or tools: they would hold a token able to
  spend money.

## Commands

Run from any folder: `bash <cloudmule-folder>/bin/cloudmule …` (the skill finds the folder in
`~/.config/cloudmule/home`). `bash bin/cloudmule help` prints the same list.

| Command | What it does | Bills? |
|---|---|---|
| `setup` | Once per computer: token, prices, SSH key, location file, Claude Code plugin | No |
| `init [folder] [--name n] [--local]` | Sets up a project (creates `.cloudmule/` from `template/`) or registers one that already has it | No |
| `projects` | Projects registered on this computer and their folders | No |
| `servers [proj] [target] [--fresh]` | With no server running, a "How to choose" guide first. Then the disk floor, and the server types available now: vCPU, RAM, disk, CPU kind, architecture, cheapest location, €/h, whether each fits the project (and why not) and what it would do to the disk floor. A `Cheaper with --fresh` line when the disk floor shuts out a cheaper type. Last line `RECOMMENDED: <type> <location> <eur/h>` | No |
| `start <proj> [target] [--type t] [--location l] [--fresh] [--dry-run]` | Joins the server (prints its type; `SERVER_BELOW_REQUIREMENTS` if it is smaller than the project needs) or creates it with the chosen type from the workspace snapshot (or plain Ubuntu), installs missing modules, runs `server-setup.sh`, syncs, installs dependencies, takes a lease. `--fresh`: ignore the saved workspace. `--dry-run`: print `WOULD_CREATE: <type> <location> <image> <eur/h>` (or `WOULD_JOIN`) and stop | **Yes, if it creates it** |
| `sync <proj> [target] [--with-generated]` | Uploads only what changed and deletes there what was deleted here | — |
| `job <proj> [target] <job> [args…]` | Syncs, runs `.cloudmule/jobs/<job>.sh` on the server and **downloads its results** | — |
| `attach <proj> [target] <job>` | Follows a job still running there and downloads its results | — |
| `pull <proj> [target] <path>…` | Downloads files or folders | — |
| `run <proj> [target] ['cmd']` | A command in the project's remote folder, or an interactive shell | — |
| `tunnel <proj> [target] <port>` | `http://localhost:<port>` here reaches `127.0.0.1:<port>` on the server (to look at something a job serves, without exposing it). Ctrl+C closes it; while open it counts as activity | — |
| `end <proj> [target] [--keep] [--forget] [--force]` | Releases the lease. If no other remains: (`--keep` → workspace snapshot) and deletes the server. `--forget`: deletes the project's folder on the server. `--force`: deletes even with other leases (only with confirmation) | Stops billing |
| `oneshot <proj> [target] <job> [args…]` | One job: uses the server if it is on; otherwise creates it and deletes it at the end if nobody else uses it (also on failure) | Yes, if it creates it |
| `leases` | Who is using the server, since when, which jobs run | No |
| `status` | Servers (billed hours), leases and snapshots | No |

`[target]` only exists for projects with `NEEDS_TARGET=1` (one sub-folder per piece of work, e.g. per video);
on the server each target lives in `/root/work/<project>/<target>`.

## A project's settings (`<project>/.cloudmule/`)

```
<project>/.cloudmule/
├── config.sh          ← PROJECT_NAME, LOCAL_DIR/REMOTE_DIR, MODULES, SYNC_EXCLUDE/SEEDS, INSTALL_* (no secrets)
├── jobs/<job>.sh      ← one script per heavy task; runs ON the server in REMOTE_DIR
├── server-setup.sh    ← optional: system tools only this project needs (once per server)
└── CLAUDE.md          ← optional: notes for agents (jobs, reference numbers, known problems)
```

- `config.sh` is sourced by bash with `$PROJECT_ROOT` (the project's folder) and `$TARGET` set. See
  `template/config.sh` for every setting.
- `MODULES` lists what the server needs (`remote/modules/<m>.sh`); `base` is always installed. Versioned
  modules (`node@24.15.0`) install into `/opt/<module>/<version>` so several versions coexist; each project's
  jobs, installs and `run` get its versions first on `PATH`.
- Jobs exit non-zero on failure and print `CLOUDMULE_RESULT <path relative to the project>` for every file or
  folder to download (paths without spaces).
- `<LOCAL_DIR>/.cloudmuleignore` adds sync exclusions, one pattern per line.
- `MIN_RAM_GB`, `MIN_CPUS`, `MIN_DISK_GB` (defaults 4 / 2 / 40) say what server the project needs; the
  architecture comes from its modules (each module declares `# arch: x86 arm`; ffmpeg is x86 only). Optional
  `SERVER_TYPES` is the project's preference order, overriding `.env`'s.

## How it works

**Hetzner bills while a server exists**, running or stopped, per started hour. So it is never "stopped": its
disk is saved as a snapshot (cents per GB per month) and it is deleted. Snapshots: `role=workspace,
scope=shared`, the whole disk of the shared server with every project (only the latest is kept). Everything
cloudmule creates carries the label `managed-by=cloudmule`.

**State on the server** lives in `/root/cloudmule/`: `leases/<project>[--<target>]` (one per active project,
refreshed by every command), `jobs/<lease>-<job>.log`, `scripts/`, `mod/<module>[@<version>]` (installed
modules) and `setup/<project>-<hash>` (server-setup done). Project files live in `/root/work/<project>/`.

**On this computer:** `.env` (token and settings; a setting given in the environment wins, e.g.
`IDLE_MINUTES=10 cloudmule start …`), `keys/` (this computer's SSH key), `registry/<project>`
(each project's folder), `logs/` (every job's log). None of it is versioned.

**Server type:** the user chooses it. `servers` reads the API's server types (`server-type list`: cores, memory,
disk, `cpu_type`, `architecture`, `prices[]`, `locations[].available`) and checks each against the project's
requirements and the saved workspace. `start --type` creates exactly that type, in the cheapest allowed location
(or `--location`). Without `--type`, `SERVER_TYPES` is tried in order, keeping only types that fit.
**A snapshot restores only on a disk at least as large as the disk it was taken from** (Hetzner answers
"image disk is bigger than server type disk"; verified 2026-11-14), so the disk of the server the workspace was
saved from is the **disk floor** for every later server (`CONTEXT.md`); `--fresh` starts from plain Ubuntu, and
the next `end --keep` replaces the saved workspace. Shared CPUs (CX, CPX) are cheaper; dedicated (CCX) give full cores for long CPU-bound work.

**Cost guard, on the server:** a systemd timer runs `remote/guard.py` every 5 min and deletes the server after
`IDLE_MINUTES` without activity (session 45, oneshot 20) or `SESSION_MAX_HOURS`/`ONESHOT_MAX_HOURS` up (8 / 3).
In a session it snapshots first: nothing is lost. Activity = an SSH connection or a job's process at one of
its 5-minute looks, and every cloudmule command (it marks the server as used, so short commands between two
looks still count). It works even
if Claude Code is closed or the computer is off. `oneshot` also deletes the server with `trap … EXIT`.

**Remote jobs** run detached from SSH (`{ nohup setsid -f bash -c … & }`), with their log copied to `logs/`. If
the connection drops or the local process is killed, the job goes on: `attach`.

**Sync** compares size and mtime of each file with the server (`find -printf` there, `os.walk` here), uploads
only what differs with `tar` over SSH and deletes there what no longer exists here. `SYNC_SEEDS` (heavy files
the server regenerates) are uploaded only when missing. Downloads use `scp`.

## Developing cloudmule

- Public repository, MIT license, everything in English. Scripts are bash 3.2-compatible (macOS) and must not
  rely on GNU-only options on the local side (`head -n -1`, `sed -i` without suffix, `sha256sum`); the server
  is Ubuntu, GNU tools are fine there.
- Never commit `.env`, `keys/`, `logs/`, `registry/` or anyone's project.
- Tests: `bash tests/run.sh` (no token, no cost: it fakes `hcloud` with recorded fixtures in `tests/fixtures/`;
  GitHub Actions runs it on Linux and macOS). It must pass before every commit. Before a release, also follow
  `docs/e2e-checklist.md` with a real token (costs a few cents: ask first). Specs live in `docs/specs/`.
- New module: `remote/modules/<name>.sh`, idempotent, pinned version, checksum verified, `apt-get update -q`
  before apt installs. Versioned modules read `$VERSION` and install into `/opt/<name>/<version>`.

## Gotchas (lessons that cost time)

- Your computer killing background commands when it runs out of RAM also kills local `cloudmule` processes:
  that is why remote work is detached and resumable (`attach`, module markers).
- Measure the network before big transfers; upload once and then only differences; analyse on the server and
  download only results. Verify big downloads with `sha256sum` on both sides.
- Missing dependencies only show up when running for real: run a real job before trusting a new setup.
- Bash: `a && b > log` only redirects `b` (group with `{ a && b; } > log`); `a && b &` backgrounds the whole
  chain (`a && { b & }`); `cmd | grep -q` under `set -o pipefail` can fail with SIGPIPE (`grep … >/dev/null`).
- `python -I` ignores `PYTHON*` variables; on Windows, Python needs Windows paths (`cygpath -w`).
- On Windows, stopping the shell task does not kill its process tree; Git Bash has no `pkill`/`pgrep` (use
  PowerShell `Get-CimInstance Win32_Process` + `Stop-Process` for a local tunnel).
- `scp -r src dest/existing` puts the folder INSIDE the existing one: copy to the parent folder.
- iOS builds need macOS and Xcode, which Hetzner does not offer. Android emulators need KVM, which Hetzner's
  cloud servers probably don't expose (`ls /dev/kvm`).
