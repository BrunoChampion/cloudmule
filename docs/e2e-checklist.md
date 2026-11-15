# Manual end-to-end checklist (before each release)

`tests/run.sh` covers everything that does not need a real server. This checklist covers the rest. It needs a
real Hetzner token and **costs money** (one started hour of the chosen server, usually a few cents): ask the
owner of the account before running it. Use a small project with one quick job; replace `<p>`/`<t>` below.

1. `cloudmule servers <p> [<t>]` — the table matches the Hetzner console's offer; the `RECOMMENDED` line is the
   cheapest `fits` row; the workspace line shows the snapshot's real disk size.
2. Snapshot disk rule (free when it holds): `hcloud server create --name cloudmule-disk-rule-check --type <a type
   whose disk is smaller than the workspace's> --image <workspace snapshot id> --location <loc>` must be rejected.
   If Hetzner accepts it, delete that server at once (`hcloud server delete cloudmule-disk-rule-check`) and drop
   the `workspace needs disk` reason from the server menu.
3. `cloudmule start <p> [<t>] --type <chosen> --dry-run` prints `WOULD_CREATE` with that type; then without
   `--dry-run`: the "Creating … EUR/h" line matches; the cost guard is armed.
4. The first start on a new layout installs the missing modules (`/root/cloudmule/mod/…` markers; versioned ones
   under `/opt/<module>/<version>`); a second `start` installs nothing.
5. `cloudmule job <p> [<t>] <job>` uploads only what changed, runs, and downloads every `CLOUDMULE_RESULT`.
6. `cloudmule leases` shows the lease; `cloudmule run <p> [<t>] 'node --version'` uses the project's version.
7. `cloudmule end <p> [<t>] --keep` creates a snapshot labelled `managed-by=cloudmule, role=workspace,
   scope=shared`, prunes the previous one, and deletes the server; `cloudmule status` shows nothing billing.
8. Cost guard, once per release: `cloudmule oneshot` a job, close the local process mid-way, and confirm the
   server deletes itself after `ONESHOT_IDLE_MINUTES` (the guard's snapshot labels are the same as in step 7).
