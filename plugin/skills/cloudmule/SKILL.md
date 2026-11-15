---
name: cloudmule
description: Run heavy development work (dependency installs, builds, test suites, project-wide typecheck/lint, dev servers, test browsers, media rendering) on a Hetzner server rented by the hour instead of this computer, and set projects up for it. Use before running such work, when the user mentions cloudmule or running something "on the server", or asks to configure cloudmule in a project.
---

# cloudmule

cloudmule keeps this computer for editing and runs heavy work on one rented server shared by all the user's
projects. It is a command-line tool in a folder the user cloned; this skill finds it and drives it.

## 1. Find cloudmule

```sh
CM="$(cat ~/.config/cloudmule/home 2>/dev/null)"; echo "${CM:-NOT INSTALLED}"
```

- **Not installed** (no file, or `$CM/bin/cloudmule` missing): say so. To install it, the user clones the
  cloudmule repository, opens Claude Code in that folder and asks "install cloudmule". Until then, do not run
  heavy work silently: follow the user's own instructions about running it locally.
- **Installed:** read `$CM/CLAUDE.md`, sections **Rules** and **Commands**, before the first command of a
  session. The rules (spending money needs confirmation, leases on the shared server) are mandatory.
- Run every command as `bash "$CM/bin/cloudmule" …` (Git Bash on Windows).

## 2. Find the project

`bash "$CM/bin/cloudmule" projects` lists the projects registered on this computer and their folders. The
current project is the one whose folder contains the working directory.

- Listed: read its `.cloudmule/config.sh`, `.cloudmule/jobs/` and `.cloudmule/CLAUDE.md` (if any).
- Not listed, but the folder has `.cloudmule/config.sh` (someone already set it up): run
  `bash "$CM/bin/cloudmule" init <project-folder>`. That only registers it.
- No `.cloudmule/`: set the project up (section 4), after telling the user what you are about to do.

## 3. Run heavy work

1. **Choose the server, with the user.** Check `status`. If the server is already running, skip to step 2:
   `start` just joins it (no choice, no new cost decision); tell the user its type, and if `start` prints
   `SERVER_BELOW_REQUIREMENTS`, tell them what is missing and let them decide. If no server is running:
   - Run `servers <project> [target]` (free). Show the user a short table of the types marked `fits`: type,
     vCPU, RAM, CPU kind (shared/dedicated), €/h and location, plus the `RECOMMENDED` line and one sentence on
     the trade-off (shared is cheaper; dedicated is steadier for long CPU-bound work; more RAM costs more).
   - If the menu says the saved workspace limits the choice (`workspace needs disk >= N GB`), explain it in
     plain words and that `--fresh` allows smaller servers at the cost of uploading and installing everything
     again once. If `RECOMMENDED: none`, explain why and what could change it.
   - **Wait for the user's choice.** Never pick for them, and never create a server without that choice.
2. `start <project> [target] --type <chosen>` creates (or joins) the server. Add `--dry-run` first if the user
   wants to see exactly what would be created. Report the type and price from the "Creating … EUR/h" line. With
   the server running, `job`, `sync`, `run`, `pull` and `attach` need no new confirmation.
3. `job <project> [target] <job> [args…]` uploads what changed, runs `.cloudmule/jobs/<job>.sh` on the server
   and downloads the files it announces. If a job needs something new (a module, a dependency), change the
   config or the job script and run it again.
4. When done: `end <project> [target] --keep`, then `status`. `end` only deletes the server when no other project
   holds a lease; if it answers `OTHER_PROJECTS_USING_THE_SERVER`, leave it and tell the user.

If the user forgets, the server snapshots itself and deletes itself after 45 idle minutes.

## 4. Set up a project

1. Look at what the project needs, from its files:

   | Found | Means |
   |---|---|
   | `package.json`, `.nvmrc`, `.node-version`, `engines.node` | `node@<that exact version>` (ask if only a range) |
   | `packageManager` in `package.json`, lockfile | the install command (`pnpm install --frozen-lockfile`, `yarn install --immutable`, `npm ci`) |
   | Playwright, Puppeteer, headless Chrome | `chrome-libs` (+ the tool's own browser download in `INSTALL_CMD`) |
   | `requirements.txt`, `pyproject.toml` | `python` (+ venv/uv install in `INSTALL_CMD`) |
   | ffmpeg in scripts | `ffmpeg` |
   | anything else (JDK, Android SDK, Go, Rust…) | `server-setup.sh`, installed into `/opt/<project>/…` with pinned versions and checksums |

   Modules available: `ls "$CM/remote/modules"`. Ask the user when unsure.

   Estimate the server it needs and write `MIN_RAM_GB`, `MIN_CPUS`, `MIN_DISK_GB` in `config.sh`, each with a
   one-line reason as a comment. Rough guide: a typical web app's tests 4–8 GB; several browsers in parallel or a
   big monorepo build 8–16 GB; Android/Gradle builds ≥ 16 GB; video rendering scales with vCPUs (8–16, dedicated
   CPUs if renders are long); disk ≥ 2–3× the project plus its dependencies. Leave the defaults when unsure.
2. Ask one question: commit `.cloudmule/` with the project (recommended: it has no secrets, and worktrees and
   teammates get it) or keep it local to this computer (`--local`, uses git's local exclude).
3. `bash "$CM/bin/cloudmule" init <project-folder> [--name <name>] [--local]`. It copies the template into
   `.cloudmule/` and, unless `--local`, adds a short note to the project's `CLAUDE.md`.
4. Edit `.cloudmule/config.sh`: `MODULES`, `SYNC_EXCLUDE` (never upload secrets, dependencies or build output),
   `INSTALL_*`. Never put secrets in `.cloudmule/`: cloudmule refuses to run if it finds any.
5. Write one job per heavy task in `.cloudmule/jobs/<job>.sh` (see `example.sh`): `set -euo pipefail`, runs in
   the project's folder on the server, prints `CLOUDMULE_RESULT <relative path>` for each file to download.
   Results usually go to a folder the project's `.gitignore` excludes.
6. Fill `.cloudmule/CLAUDE.md` with the jobs table, then run a first job to prove it works.
