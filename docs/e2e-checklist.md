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
3. `cloudmule start <p> [<t>] --type <chosen> --dry-run` prints `WOULD_CREATE` with that type and `WOULD_LABEL`;
   then without `--dry-run`: the "Creating … EUR/h" line matches; the cost guard is armed; `hcloud server describe
   cloudmule` shows the `chosen-type/-by/-at` labels.
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

8. Cost guard, once per release: `cloudmule oneshot <p> --type <chosen> <job>`, close the local process mid-way,
   and confirm the server deletes itself after `ONESHOT_IDLE_MINUTES`. In session mode (`IDLE_MINUTES=10 cloudmule
   start …`) the guard's snapshot carries the same labels as step 7's, `chosen-*` included (`cloudmule servers`
   then shows that last choice).

## RunPod GPU pods (spec 0004)

Needs a RunPod key in `.env` (able to manage pods, with "catalog read") and credit; **costs money** (a few US
cents per run on the cheapest SECURE GPU): ask the owner of the account first. Use a project with
`NEEDS_GPU=graphics` and a job that runs `cloudmule-webgl-check` and prints the renderer.

9. `cloudmule gpus <p>` — the table matches RunPod's console (prices, VRAM); availability is not all `NONE`;
   `RECOMMENDED` is a fitting SECURE GPU. With a key lacking "catalog read": `RUNPOD_FORBIDDEN` and the hint.
10. `cloudmule gpu <p> --gpu "<recommended>" --dry-run <job>` prints `WOULD_CREATE`; then with `--approved`
    (the spec asks for the cheapest available SECURE GPU: if `RECOMMENDED` is not the cheapest `fits` row, use that):
    the pod is created, SSH answers within a few minutes, the pod guard is armed, `gpu-graphics` installs
    (Google's key fingerprint check passes), `cloudmule-webgl-check` reports an **NVIDIA** renderer, the job runs,
    results come back, the pod is deleted (`GPU pod … deleted:` line) and the RunPod console shows no pod.
    Note how long creation → SSH and the setup took. Verify on the pod (before it ends, `ssh` with the run's key, or
    in the job): which of `createdAt` / `runtime.uptimeInSeconds` `GET /pods` returns (orphan ages), that
    `RUNPOD_POD_ID` and a pod-scoped `RUNPOD_API_KEY` are in `/proc/1/environ`, and that `runpodctl` exists.
    Also look for a public-IP filter for COMMUNITY pods (`supportPublicIp` in the catalog or `POST /pods`): if it
    exists and gives public SSH, COMMUNITY can be allowed (spec 0004); record the answer here.
11. Guard inside the pod: set `RUNPOD_MAX_MINUTES=5` **in `.env`** (the caps are read only from there), start a
    `gpu` job that takes longer, kill the local process tree as soon as the pod guard is armed **and** the local
    watchdog (PowerShell `Get-CimInstance Win32_Process` → the `rp-reap` python → `Stop-Process`). Within about
    5 min the pod must disappear from the RunPod console on its own (layer 3). If it only stops (still listed),
    `runpodctl`/the pod-scoped key did not work: record it here and in the spec. Restore `RUNPOD_MAX_MINUTES`.
12. `cloudmule status` lists no `cloudmule-*` pod (an orphan from step 11 would be deleted here with
    `ORPHAN_DELETED`); `cloudmule usage <p>` shows the GPU job with its GPU, minutes and cost, close to what RunPod's
    billing page shows.

Last RunPod run: 2026-11-18. Steps 9–11 passed (A40 probe 5.8 min ≈ 0.057 USD; RTX 4000 Ada guard test: the pod
deleted itself). Step 12: `status` and `usage` correct (0.08 USD in all), but not yet compared with RunPod's billing
page line by line: the key cannot read billing; the console showed 0.17 USD spent that day, including the
prototype benchmark, vs about 0.09 USD estimated for cloudmule's pods (Billing Explorer reconciles per pod). `supportPublicIp`: REST v2 rejects it (HTTP 422): COMMUNITY stays
unusable. Details in spec 0004, Further Notes.
