# Manual end-to-end checklist (before each release)

`tests/run.sh` covers everything that does not need a real server. This checklist covers the rest. It needs a
real Hetzner token and **costs money** (one started hour of the chosen server, usually a few cents): ask the
owner of the account before running it. Use a small project with one quick job; replace `<p>`/`<t>` below.

1. `cloudmule servers <p> [<t>]` — the table matches the Hetzner console's offer; the `RECOMMENDED` line is the
   cheapest `fits` row; the workspace line shows the snapshot's real disk size.
2. Snapshot disk rule (free when it holds): `hcloud server create --name cloudmule-disk-rule-check --type <a type
   whose disk is smaller than the workspace's> --image <workspace snapshot id> --location <loc>` must be rejected.
   (Verified 2026-11-14: rejected with "image disk is bigger than server type disk", nothing billed.)
   If Hetzner ever accepts it, delete that server at once (`hcloud server delete cloudmule-disk-rule-check`) and drop
   the disk floor (`below disk floor`) from the server menu.
3. `cloudmule start <p> [<t>] --type <chosen> --dry-run` prints `WOULD_CREATE` with that type; then without
   `--dry-run`: the "Creating … EUR/h" line matches; the cost guard is armed.
4. The first start on a new layout installs the missing modules (`/root/cloudmule/mod/…` markers; versioned ones
   under `/opt/<module>/<version>`); a second `start` installs nothing.
5. `cloudmule job <p> [<t>] <job>` uploads only what changed, runs, and downloads every `CLOUDMULE_RESULT`.
   `cloudmule usage <p>` then shows that job with a real peak RAM, RAM wait and cores (not `n/a`): the systemd
   scope, the kernel's `memory.peak` and `memory.pressure` (PSI) work on the server's Ubuntu. `cloudmule leases`
   during a job shows "jobs running: 1" (not 2 or 3). Run a job whose command fails: its usage line is
   still recorded, with the exit code.
6. `cloudmule leases` shows the lease; `cloudmule run <p> [<t>] 'node --version'` uses the project's version.
7. `cloudmule end <p> [<t>] --keep` creates a snapshot labelled `managed-by=cloudmule, role=workspace,
   scope=shared`, prunes the previous one, and deletes the server; `cloudmule status` shows nothing billing.
Last full run: 2026-11-15 (v0.1.0) on a CPX62 in hel1, about €0.21: steps 1–6 passed; the guard (step 8, in
session mode with `IDLE_MINUTES=10`) snapshotted with the right labels and deleted the server, but it measured
idleness from its last 5-minute look instead of the last command; fixed by having every command mark the
server as used. Step 7's API sequence is covered by `tests/run.sh`.

8. Cost guard, once per release: `cloudmule oneshot` a job, close the local process mid-way, and confirm the
   server deletes itself after `ONESHOT_IDLE_MINUTES` (the guard's snapshot labels are the same as in step 7).
