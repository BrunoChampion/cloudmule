# Spec 0002 — Choosing a server with the disk floor in sight, and measuring what jobs use

Status: part 1 (menu, skill) implemented 2026-11-16; part 2 (job measurement) in progress · Written 2026-11-16 · Scope: the cloudmule repository only.
Vocabulary: see `CONTEXT.md` (shared server, lease, workspace, **disk floor**).

## Problem Statement

The user wants to cut what cloudmule costs them, and cannot today, for two reasons.

**They choose servers without seeing the consequence that matters most.** Spec 0001 made the snapshot rule
visible, but only after the fact. The workspace restores only on a disk at least as large as the disk it was saved
from, so every server's disk becomes the minimum for every later one: the **disk floor**. The menu warns with a
single generic line ("the first server's disk size will limit later restores") and, once the floor is set, marks
the excluded types `no: workspace needs disk >= N GB (or --fresh)`; the skill then shows the user only the types
that fit, so the cheaper excluded ones are never seen. On 2026-11-16 a CPX62 (640 GB) was chosen after a CPX42
(320 GB); since then only CPX62 (€0.21/h) and CCX63 (€1.37/h) can restore the workspace, while a CPX42
(€0.11/h) or CPX32 (€0.06/h) meets both projects' declared needs. Nothing in the menu said, next to the CPX62's
price, that choosing it would lock every later server to 640 GB. Nor does anything explain, up front, the
trade-offs between server families (shared or dedicated CPU, RAM, disk, ARM, how billing works).

**They have no data on what their jobs need.** cloudmule does not measure RAM or CPU, so "would 16 GB be enough
instead of 32?" cannot be answered. Meanwhile full job logs accumulate in `logs/` with no limit (229 files in two
days).

## Solution

1. **`servers` explains before the table, only when a choice is due** (no server running): a fixed "How to
   choose" guide of about five lines, then a disk-floor block (the current floor, or "the server you create now
   sets the disk floor").
2. **Each row says what choosing it does to the disk floor**, in its verdict: `fits; raises disk floor 320 -> 640
   GB (N types lost)`, or `fits; sets disk floor to 640 GB (N types lost)` when there is no workspace yet.
3. **An escape line** when the disk floor shuts out a cheaper type that would fit: what it saves per hour, and
   the one-time cost of `--fresh`.
4. **The skill relays all of this** in plain words, in the user's language, before its short table.
5. **Every remote job is measured automatically** by the kernel (its own cgroup: peak RAM, CPU time). cloudmule
   keeps **one summary line per job** in a local file capped by age, and a new `usage` command summarises it per
   project and job. Full job logs older than `LOG_KEEP_DAYS` are deleted automatically.

The output of `servers` is the single source of truth: the skill never restates the rules, it relays them.

## User Stories

### Choosing a server

1. As a user about to create the shared server, I want a short guide to the server families and their trade-offs
   before the table, so that I know what I am choosing between.
2. As a user, I want each type's row to say whether choosing it raises the disk floor, to how much, and how many
   types I would lose, so that I see the long-term cost next to the hourly price.
3. As a user creating the first server (or after `--fresh`), I want to be told that this choice sets the disk
   floor, and which rows would set it higher than necessary.
4. As a user whose disk floor already shuts out cheaper types, I want one line telling me the cheapest of them,
   what it saves per hour and what `--fresh` costs once, so that I can decide to escape.
5. As a user joining a server that is already running, I do not want the guide (there is no choice to make).

### Measuring jobs

6. As a user, I want every job's peak RAM, average CPU, duration, server type and outcome recorded without anyone
   having to remember to do it, so that the data is complete and trustworthy.
7. As a user, I want `cloudmule usage [project]` to show, per project and job, the highest peak RAM and CPU seen,
   so that I can choose a smaller server with evidence.
8. As a user, I want the usage file and the job logs not to grow without limit.

## Implementation Decisions

### `servers` (only the menu changes; `start` keeps its behaviour)

- **When:** the guide and the disk-floor block print only when no shared server exists. When one is running, the
  current "Running now … Joining it needs no choice" text stays and the guide is omitted.
- **Guide** (fixed text, about five lines): shared vCPU (CX, CPX) cheapest, speed varies with neighbours;
  dedicated (CCX) full cores for long renders and builds; RAM is the most expensive dimension, pick what the jobs
  actually peak at (mention `cloudmule usage` once it exists); a bigger disk raises the disk floor for every later
  server; billing per started hour while the server exists, the workspace costs cents per GB per month (the
  `hcloud` CLI has no pricing command, so no exact figure); ARM (CAX) cheapest per core but some modules are x86
  only.
- **Disk-floor block:** with a workspace, `Disk floor: N GB (the workspace was saved from an N GB disk). A bigger
  disk raises it for every later server; only --fresh lowers it.` Without one: `No workspace yet: the server you
  create now sets the disk floor.`
- **Reference disk:** the current disk floor; without a workspace, the smallest disk among the types that fit.
  Rows whose disk equals the reference carry no warning.
- **Verdict suffix** for fitting rows above the reference: `raises disk floor R -> D GB (N types lost)` or, with
  no workspace, `sets disk floor to D GB (N types lost)`.
- **"N types lost"** counts types available in the allowed locations, with the row's architecture (the
  workspace will have it), whose disk is >= the reference and < D. It ignores the current project's requirements,
  because the server is shared and another project may want a small one.
- **Server running:** the next workspace will be saved from it, so its disk is the next disk floor (`Disk floor
  next time: N GB`), and the table is computed against it.
- **Escape line:** when some type fits the project except for the disk floor and is cheaper than the
  recommendation, print the cheapest one: `Cheaper with --fresh: <type> <eur/h> EUR/h (saves <diff> EUR/h). One-time
  cost: every project uploads and installs again on the first start, and the next end --keep lowers the disk floor
  to <disk> GB.`
- Machine-readable lines (`RECOMMENDED: …`) keep their format. The reason text changed to the new vocabulary in
  the menu and in `start`'s `NO_FITTING_SERVER` refusal: `below disk floor N GB (or --fresh)`.
- Refinements from the code review: the escape line considers only types kept out by the disk floor alone (not
  by the workspace's architecture); it is omitted while a server runs (`start` would join it) and when no project
  is given; when nothing fits it still prints, as "(nothing fits without it)". A fitting row that would lose no
  available type carries no warning.

### Skill (`plugin/skills/cloudmule/SKILL.md`, section 3 step 1)

- Before the short table, relay the guide and the disk-floor block in plain words in the user's language; mark
  the rows that raise or set the disk floor; always mention the escape line when present. Keep "wait for the
  user's choice".
- Follow `/writing-for-agents`; the skill does not restate the rules that `servers` prints.

### Job measurement

- `remote_job` (`bin/lib.sh`) runs each job in its own cgroup v2 (a transient systemd scope). The wrapper, inside
  that cgroup, runs the job and afterwards reads its own cgroup's `memory.peak` and `cpu.stat` (`usage_usec`), then
  writes one summary line next to the job's log (`$R/jobs/<name>.usage`). This applies to every remote job,
  module installs included.
- `remote_wait` (used by `job` and `attach`) downloads that line and appends it locally with: date, project,
  target, job, server type, duration, peak RAM (GB) / server RAM, average cores used (CPU time / duration) /
  vCPUs, exit code. About 100 bytes per job.
- Local file: `logs/usage.tsv`. On every append, lines older than `USAGE_KEEP_DAYS` (default 90) are dropped.
- Full job logs: `logs/*.log` older than `LOG_KEEP_DAYS` (default 14) are deleted on every job. `usage.tsv` is
  never deleted by this.
- New read-only command `usage [project] [target]`: per job, number of runs, highest peak RAM, highest and typical
  average cores, longest duration, and the server types seen.
- If the kernel does not expose `memory.peak` (cgroup v1, old kernel), the line records `n/a` and the job is
  unaffected. To verify on the first real job (Ubuntu 24.04 ships kernel 6.8, where `memory.peak` exists).

## Testing Decisions

- Through the `cloudmule` CLI as a black box with the fake `hcloud` (`tests/fixtures/`), as in spec 0001.
- Menu: with a workspace (verdict suffixes, N types lost, escape line present), without one (`sets disk floor`,
  reference = smallest fitting disk, no suffix on it), no escape line when nothing cheaper is shut out, server
  running (no guide).
- Usage: the parsing and age cap of `usage.tsv`, the `usage` summary, and `LOG_KEEP_DAYS` pruning, with fixture
  lines. The cgroup reading itself runs only on a real server (e2e checklist).
- `bash tests/run.sh` is light (fake `hcloud`), but the user's global rule counts test suites as heavy: ask before
  running it.

## Out of Scope

- A history of servers created and deleted, with hours billed and cost per day and project (`cloudmule history`).
  Proposed, not yet agreed. If done, written by `start`/`end` in code, reconstructing guard deletions from the
  time of the snapshot the guard leaves.
- Using measured usage in the recommendation ("your jobs peaked at 6 GB, a CPX42 is enough"). Next step, once
  there is data.
- Keeping the disk small while scaling CPU and RAM (Hetzner's change-type keeping the original disk). Needs
  checking against Hetzner's docs and a paid test.
- Escaping the current 640 GB disk floor: a one-time `start --fresh` on a smaller type, then `end --keep`. An
  operation for the user to decide, when no other session holds a lease.

## Further Notes

State when this spec was written (2026-11-16), so the work can resume after any context loss:

- Servers created on 2026-11-15/16, reconstructed from Claude Code transcripts (cloudmule records no history):
  CPX62 (nyvex), 4× CCX33 (YouTube; the first from plain Ubuntu), CPX42 (Charlio, 02:38 UTC), then 3× CPX62
  (Charlio, from 03:19 UTC). The workspace (snapshot 457207116, 11.75 GB) came from a CPX62: disk floor 640 GB.
- Declared needs: Charlio 8 GB / 4 vCPU / 80 GB; YouTube 16 GB / 8 vCPU / 80 GB (`SERVER_TYPES="ccx33 cpx42
  cpx52"`). `.env`: `SERVER_TYPES="cx53 cpx62"` (CX53 unavailable).
- Code touched: `servers` in `bin/cloudmule`; `menu`/`fit_reasons` in `bin/tools.py`; `remote_job`/`remote_wait`
  in `bin/lib.sh`; the skill; `CLAUDE.md` commands table (`usage`, the two `*_KEEP_DAYS` settings);
  `.env.example`.
- Order of work: the menu and the skill first, then job measurement. No tickets: both fit one session.
- Decisions taken in a grilling session with the user on 2026-11-16: single source of truth in `servers` output;
  the term "disk floor"; warnings in the verdicts; the escape line; reference = smallest fitting disk when there
  is no workspace; guide only when no server is running; measurement automatic and deterministic in code, one
  line per job, capped.
