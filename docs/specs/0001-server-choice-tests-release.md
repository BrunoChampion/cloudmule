# Spec 0001 — Server choice, automated tests and first public release

Status: ready for implementation · Written 2026-11-14 · Scope: the cloudmule repository only.

## Problem Statement

cloudmule rents one Hetzner server for the heavy work of all of a user's projects, but the user has no say in
**which** server: it silently takes the first available type from a fixed list (`cx53 cpx62`). Projects differ:
a web app's tests run fine on 8–16 GB, an Android build wants 16 GB or more, a long video render wants many
CPUs, some tools only run on x86. The user wants to see the options that fit their project — 16, 32 or 64 GB,
shared or dedicated CPUs, and what each costs per hour — and pick one, the way they would pick a rental car.

There is also a trap the user cannot see today: a workspace snapshot can only be restored on a server whose disk
is at least as large as the disk the snapshot came from. The current workspace snapshot came from a CPX62
(640 GB disk), so today only CPX62 and CCX63 can restore it, and the preferred CX53 (320 GB) would fail. Nothing
warns about this, and nothing tells the user that the size of their first server limits every later choice.

Finally, cloudmule is about to be published for other people, but it has no automated tests in the repository
(the fresh-install simulation lives in a scratch folder), it is untested on macOS and Linux, nothing is committed
yet, and the README still says `<owner>`.

## Solution

1. **A server menu.** A new read-only command lists the server types Hetzner has available right now in the
   allowed locations, with vCPU, RAM, disk, CPU kind (shared or dedicated), architecture, the cheapest location
   and its hourly price. Each row says whether it **fits this project** and, if not, why (too little RAM, wrong
   architecture, disk too small for the saved workspace, not available). It ends with a recommendation.
2. **Projects declare what they need.** A project's settings can state its minimum RAM, CPUs and disk. Modules
   declare which CPU architectures they support, so the menu knows a project with ffmpeg needs x86.
3. **The user chooses; the agent asks.** The skill tells the agent: before creating a server, show the user the
   options that fit, recommend one, and wait for the user's choice. `start` then creates exactly that type.
   Joining a server that is already running needs no choice, but the agent says which type it is and warns if it
   is below the project's needs.
4. **The snapshot trap is visible and escapable.** The menu explains the workspace's disk constraint; `start`
   refuses a type that cannot restore the workspace and explains the way out (`--fresh`: start from a clean
   Ubuntu and let the next snapshot replace the old workspace).
5. **A dry run.** `start --dry-run` prints what would be created (type, location, image, price) and creates
   nothing. It is useful to users, and it is the seam the tests use.
6. **Tests and release.** The fresh-install simulation moves into the repository as a test suite that fakes the
   Hetzner CLI, runs without a token or money, and later runs on GitHub Actions on Linux and macOS. Then the
   first commit and the public GitHub repository.

## User Stories

### Choosing a server

1. As a cloudmule user, I want to list the server types I can rent right now, so that I can choose one instead of getting whatever comes first.
2. As a cloudmule user, I want each option to show vCPUs, RAM, disk, CPU kind and architecture, so that I can compare them like products.
3. As a cloudmule user, I want each option to show its hourly price including VAT in the cheapest allowed location, so that I know what an hour costs before I start.
4. As a cloudmule user, I want to see which location each price belongs to, so that I understand where my code will run.
5. As a cloudmule user, I want options that don't fit my project to be marked with the reason, so that I understand why a cheaper one isn't suggested.
6. As a cloudmule user, I want unavailable types to be marked as unavailable, so that I don't pick something Hetzner cannot give me now.
7. As a cloudmule user, I want a recommended option, so that I can just accept a sensible default.
8. As a cloudmule user, I want the recommendation to be the cheapest option that fits my project, so that I don't overpay.
9. As a cloudmule user, I want to be told when a dedicated-CPU option is worth it (long CPU-bound work such as renders), so that I can trade money for speed knowingly.
10. As a cloudmule user, I want listing the options to never create anything or cost money, so that I can look as often as I like.
11. As a cloudmule user, I want to create exactly the type I chose, so that my choice is respected.
12. As a cloudmule user, I want to optionally choose the location too, so that I can keep my code in a specific country.
13. As a cloudmule user, I want a dry run of `start` that shows type, location, image and price without creating anything, so that I can check before paying.
14. As a cloudmule user who runs cloudmule by hand, I want `start` without an explicit type to still work by taking the first fitting type from my preference list, so that the manual workflow stays short.
15. As a cloudmule user, I want my preference list to skip types that don't fit the project, so that a manual `start` never creates a server my project can't use.

### Project requirements

16. As a project owner, I want to declare the minimum RAM my project needs, so that smaller servers are never offered.
17. As a project owner, I want to declare the minimum number of CPUs, so that heavy parallel work isn't run on a tiny server.
18. As a project owner, I want to declare the minimum disk, so that a large repository and its dependencies fit.
19. As a project owner, I want all requirements to be optional with safe defaults, so that simple projects need no extra settings.
20. As a project owner, I want the architecture requirement to come from the modules my project uses, so that I don't have to know that ffmpeg's build is x86-only.
21. As a project owner, I want the agent that sets up my project to suggest the requirements with a reason written next to them, so that I can review and adjust them later.
22. As a project owner, I want to optionally list preferred server types for my project, so that my project's sensible choice is offered first.

### Shared server and snapshots

23. As a user with several projects, I want to be told which type the shared server is when it is already running, so that I know what my job will run on.
24. As a user, I want a clear warning when the running shared server is smaller than my project needs, so that I can decide whether to wait, ask, or continue.
25. As a user, I want the menu to say that a running server cannot change size while other projects use it, so that I don't expect a resize mid-session.
26. As a user, I want the menu to explain the saved workspace's minimum disk size, so that I understand why some types can't restore it.
27. As a user, I want `start` to refuse a type that cannot restore the workspace and explain why, so that I never wait for a creation that will fail.
28. As a user, I want a `--fresh` start that ignores the saved workspace, so that I can move to a smaller or different server.
29. As a user, I want `--fresh` to warn me that the next saved workspace will replace the old one and that every project will upload and install again, so that I don't lose state by surprise.
30. As a new user, I want the docs to tell me that my first server's disk size limits what later restores can use, so that I choose my first server deliberately.

### The skill and the agent

31. As a Claude Code user, I want the agent to show me the fitting options before it creates a server, so that every spending decision is mine.
32. As a Claude Code user, I want the agent to present the options as a short table with RAM, CPUs, price and its recommendation, so that choosing takes seconds.
33. As a Claude Code user, I want the agent to not ask again when the server is already running, so that joining stays quick.
34. As a Claude Code user, I want the agent to report the type and price it actually created, so that I can track spend.
35. As a Claude Code user, I want the agent, when setting up a project, to estimate RAM/CPU/disk needs from the project (for example Gradle/Android builds, video rendering, browser test suites), so that the menu is filtered sensibly from the first day.
36. As a Claude Code user, I want the agent to tell me when a server is too small for the project while it is already running, so that I can decide what to do.

### Tests and portability

37. As a cloudmule maintainer, I want the fresh-install simulation to live in the repository, so that anyone can run it before changing cloudmule.
38. As a maintainer, I want tests that run without a Hetzner token and without spending money, so that they can run anywhere, including CI.
39. As a maintainer, I want the tests to fake the Hetzner CLI with recorded answers, so that the server menu, filtering and type selection are tested deterministically.
40. As a maintainer, I want the tests to use an isolated home folder and Claude Code config, so that running them never touches my real setup.
41. As a maintainer, I want one command to run the whole suite and a clear pass/fail summary, so that checking is effortless.
42. As a maintainer, I want the suite to run on GitHub Actions on Linux and macOS, so that portability problems (bash 3.2, BSD tools) show up before users hit them.
43. As a maintainer, I want a written manual end-to-end checklist with a real token, so that the parts that need a real server (modules, jobs, snapshots, guard) are verified before each release.

### Release

44. As the author, I want the first commit to contain only the tool (no tokens, keys, logs, registry or personal projects), so that the public history is clean from the start.
45. As the author, I want commits published under a GitHub no-reply e-mail, so that my personal e-mail is not public.
46. As the author, I want the README's install command to point at the real public repository, so that people can copy it.
47. As the author, I want credit to Bruno Champion and NYVEX in the README, LICENSE and plugin metadata, so that the work is attributed.
48. As a new user, I want to install the plugin from the public repository in one command, so that installing is simple even without cloning by hand first.
49. As a new user, I want the plugin to have an icon, so that it looks finished in plugin listings.

## Implementation Decisions

### Server menu (new command `servers`)

- New read-only command: `cloudmule servers <project> [target]` (project optional: without it, no project
  requirements are applied). It needs the token, never creates anything, and does not take a lease.
- Data source: the API's server type list (cores, memory, disk, `cpu_type` shared/dedicated, `architecture`
  x86/arm, `prices[]` per location with gross hourly price, `locations[].available`), the workspace snapshot's
  `disk_size` and `architecture` (image describe), and the running shared server, if any.
- Output: a header (running server and its type, if any; workspace snapshot size and its minimum disk; the
  project's effective requirements and where each comes from), then one row per non-deprecated type in the
  allowed `LOCATIONS`: type, vCPU, RAM, disk, CPU kind, architecture, cheapest available location, EUR/h, and a
  verdict: `fits`, or `no: <reason>` with reasons `ram < N`, `cpus < N`, `disk < N`, `arch`, `workspace needs
  disk ≥ N GB` (fixable with `--fresh`), `unavailable`. Sorted by fits first, then price. A final machine-readable
  line `RECOMMENDED: <type> <location> <eur/h>` (the cheapest fitting type), or `RECOMMENDED: none` with the
  reason.
- The filtering logic lives in the Python helper (same place as today's `candidates`), so the shell stays thin
  and the logic is testable through the CLI.

### Project requirements

- New optional settings in a project's `config.sh`: `MIN_RAM_GB` (default 4), `MIN_CPUS` (default 2),
  `MIN_DISK_GB` (default 40), `SERVER_TYPES` (project preference order, overrides `.env`'s for that project).
- Module architecture metadata: every module script declares the architectures it supports in a header line
  (`# arch: x86 arm`). The project's required architectures = intersection over its `MODULES` plus `base`.
  Today: `base`, `node`, `chrome-libs`, `python` support x86 and arm; `ffmpeg` (BtbN `linux64` asset) is x86 only.
- Effective disk requirement = max(`MIN_DISK_GB`, workspace snapshot `disk_size` when restoring). The snapshot
  rule (a snapshot restores only on a disk ≥ its source disk) must be verified once against the real API when
  implementing; if Hetzner allows smaller disks, drop that reason.
- The workspace snapshot's architecture also constrains restores (an x86 snapshot cannot boot on arm).

### `start` changes

- `--type <type>` (exists) becomes the normal path; the skill always passes it after the user's choice.
  New: `--location <loc>` (optional; must be in `LOCATIONS`), `--fresh` (ignore the workspace snapshot, start from
  `BASE_IMAGE`), `--dry-run` (print `WOULD_CREATE: <type> <location> <image> <eur/h>` and exit 0, nothing created).
- Without `--type`: take the project's `SERVER_TYPES` (or `.env`'s), keep only fitting and available types, try
  them in order (existing behaviour, now filtered).
- A chosen type that does not fit fails before any API write, with the menu's reason; a type that cannot restore
  the workspace fails with the hint to use `--fresh` or a larger type.
- `--fresh` prints a warning: the next `end --keep` replaces the saved workspace (only one is kept), so every
  project uploads and installs again on that server. It refuses if another server already exists.
- When the shared server is already running, `start` joins it as today, prints its type, and prints
  `SERVER_BELOW_REQUIREMENTS: <reasons>` if it is smaller than the project needs (it does not refuse: other
  projects may be using it; the agent tells the user).
- Default `SERVER_TYPES` in `.env.example` and docs: explain the choice instead of a silent `cx53 cpx62`; keep a
  fallback list but document that the first server's disk limits later restores.

### Skill and docs

- The skill gets a "Choose the server" step before `start` when no server is running: run `servers <project>`,
  show the user a compact table of the fitting options (RAM, vCPU, CPU kind, EUR/h, location) plus the
  recommendation and one line on the trade-off (shared vs dedicated, more RAM vs price), wait for the choice,
  then `start --type <chosen>` (with `--dry-run` first if the user wants to see it). When the server is running:
  join, report its type, relay `SERVER_BELOW_REQUIREMENTS` if printed.
- The skill's project set-up step adds: estimate `MIN_RAM_GB`/`MIN_CPUS`/`MIN_DISK_GB` from the project
  (examples: Android/Gradle ≥ 16 GB; video rendering benefits from many vCPUs and dedicated CPUs; a typical
  web test suite 4–8 GB) and write them with a one-line reason as a comment.
- The template's `config.sh` documents the new settings. `CLAUDE.md` (commands table, rules: listing is free,
  creating needs the user's choice and confirmation) and the README (Use, What it costs, the snapshot disk
  note) are updated.

### Tests (one seam: the `cloudmule` CLI as a black box)

- The test seam is the CLI itself, run as a user would, with three substitutions: an isolated `HOME`, an isolated
  Claude Code config dir (`CLAUDE_CONFIG_DIR`), and a **fake `hcloud`** first on `PATH`. No other seam is added.
- The fake `hcloud` is a small script that answers the subcommands cloudmule uses (`server-type list/describe`,
  `image list/describe`, `server list/ip/describe`, `ssh-key list/describe`) from recorded JSON fixtures (captured
  from the real API, without personal data), selects a scenario through an environment variable (e.g. "no
  server, 640 GB workspace", "no snapshot", "server running cpx62", "cx types unavailable"), and appends every
  call to a log so tests can assert that nothing was created (no `server create` call during `servers` or
  `--dry-run`).
- SSH is not faked: commands that need a running server are covered by the manual end-to-end checklist.
- The suite is a single bash runner in the repository with a pass/fail summary and a non-zero exit on failure,
  bash 3.2-compatible. It includes the existing fresh-install checks (clone contents, help without token,
  init/registry/home pointer, re-init idempotence, name clash, project inside cloudmule refused, `--local`,
  secret detection, unknown module, plugin install into an isolated Claude config with no secrets copied) and the
  new server-choice checks.
- CI (after everything else): a GitHub Actions workflow running the suite on `ubuntu-latest` and
  `macos-latest` on every push and pull request; no secrets, no token.

### Release

- First commit of the repository only after the tests pass, with the author e-mail set to the user's GitHub
  no-reply address for this repository; `git status` must show no `.env`, `keys/`, `logs/`, `registry/`.
- Create the public GitHub repository (name `cloudmule`), push, replace `<owner>` in the README, and document the
  one-step plugin install from GitHub (`/plugin install cloudmule --marketplace <owner>/cloudmule`).
- Add a square plugin icon (512–2048 px PNG) — the validator warns about it; optional, low priority.
- Version stays `0.1.0` in `plugin.json` and the marketplace entry; tag the release once published.

## Testing Decisions

- A good test drives cloudmule exactly like a user (commands, arguments, files on disk) and asserts only on
  what a user can observe: exit codes, printed lines (especially the stable markers `RECOMMENDED:`,
  `WOULD_CREATE:`, `SERVER_BELOW_REQUIREMENTS:`, `INIT_OK`, error messages), files created in the project and
  home folder, and the fake `hcloud` call log. Tests never call internal shell functions or Python helpers
  directly.
- Covered through the seam: the server menu (fit verdicts and reasons for RAM, CPUs, disk, architecture,
  workspace disk, availability; sorting; recommendation; project-less listing), requirement defaults and
  overrides, module architecture intersection, `start --dry-run` with and without `--type`, with `--fresh`,
  with an unfitting type, with a type too small for the workspace, project `SERVER_TYPES` overriding `.env`, and
  joining a running server below requirements (dry run only); plus every fresh-install check that exists today.
- Prior art: the fresh-install simulation used during the rename (isolated `HOME` and `CLAUDE_CONFIG_DIR`, a
  copy of exactly the files a clone would get, PASS/FAIL lines and a failure count). It moves into the repository
  and grows the fake `hcloud`.
- Manual end-to-end checklist (real token, costs a few cents, needs the account owner's confirmation), kept in
  the repository: `servers`; `start --type <chosen>` restores the saved workspace; modules install with the new
  markers (versioned ones under `/opt/<module>/<version>`); a short job downloads a `CLOUDMULE_RESULT`; `leases`;
  `end --keep` creates a snapshot labelled `managed-by=cloudmule` and prunes the old one; `status` shows nothing
  billing; the snapshot disk rule is checked once; the guard is seen firing on a oneshot.

## Out of Scope

- Anything outside the cloudmule repository (the author's own projects and old setup).
- Resizing a running shared server (Hetzner can change type while powered off), automatic scaling, or several
  servers at once.
- ARM support for ffmpeg (BtbN also publishes `linuxarm64`), and ARM servers in general beyond what the
  architecture metadata allows.
- Docker/devcontainer-based jobs; removing the dependency on the `hcloud` CLI; renting a Mac for manual tests.
- Other clouds than Hetzner.

## Further Notes

State when this spec was written (2026-11-14), so the work can resume after any context loss:

- Commands before this spec: `setup`, `init`, `projects`, `start`, `sync`, `job`, `attach`, `pull`, `run`,
  `tunnel`, `end`, `oneshot`, `leases`, `status`. Projects keep settings in `<project>/.cloudmule/` (`config.sh`,
  `jobs/`, optional `server-setup.sh` and `CLAUDE.md`), registered per computer in `registry/`;
  `~/.config/cloudmule/home` points the skill to the tool. Modules are declared per project (`MODULES`, versioned
  ones like `node@24.15.0` under `/opt/<module>/<version>`); there are no profiles or base images; the first
  `start` without a workspace snapshot boots plain Ubuntu.
- The author's existing workspace snapshot came from a CPX62 (`disk_size` 640 GB, x86, 27.5 GB of data); no real
  server had been started with the new layout yet.
- Available server types observed on 2026-11-14 in nbg1/fsn1/hel1: CPX12–CPX62 (shared x86, CPX62 16 vCPU /
  32 GB / 640 GB ≈ €0.21–0.25/h), CCX13–CCX63 (dedicated x86, CCX43 16 vCPU / 64 GB / 360 GB, CCX53 32 vCPU /
  128 GB, CCX63 48 vCPU / 192 GB / 960 GB), CX23 only among CX (CX53 unavailable), no CAX (ARM) available.
  With the current workspace (640 GB disk) only CPX62 and CCX63 could restore it.
- Order of work: server menu and requirements → `start` options → skill and docs → tests in the repository →
  manual end-to-end check (with the user's confirmation) → first commit and GitHub publication (with the user's
  confirmation) → GitHub Actions.
- The project issue tracker is not configured (no GitHub remote yet), so this spec lives in the repository; it
  can be published as an issue once the repository is on GitHub.
