# cloudmule privacy policy

Last updated: 2026-11-18

cloudmule is an open-source tool (MIT) that runs the heavy work of your software projects on a Hetzner Cloud
server in **your own Hetzner account**. It has no backend, no accounts and no telemetry: **the author (Bruno
Champion / NYVEX) receives no data from you**, and cloudmule sends nothing to anyone other than Hetzner, on your
behalf (and to RunPod, only for work that needs a GPU and only if you set it up).

## What data cloudmule handles, and where it goes

| Data | Where it is kept | Where it is sent |
|---|---|---|
| Your Hetzner API token | `.env` in your cloudmule folder, on your computer | To the Hetzner Cloud API (to manage your servers), and to your own server's memory (`/run/cloudmule/token`, a RAM disk, never written to its disk or snapshots) so its cost guard can snapshot and delete that server when idle |
| Your RunPod API key (optional) | `.env` in your cloudmule folder, on your computer | To the RunPod API only (to list GPUs and create and delete your pods). Never to a pod: a pod deletes itself with its own pod-scoped credentials |
| Your computer's SSH key | `keys/` in your cloudmule folder (private key never leaves your computer) | Public key only: registered in your Hetzner account as `cloudmule-<computer-name>` |
| Your computer's name | — | Part of the SSH key's name in your Hetzner account, and of the lease file on your server that says which computer is using it |
| Your project's files | Your project folder | Uploaded over SSH to your server (`/root/work/<project>/`), except what the project excludes (`SYNC_EXCLUDE`; `.env` files are excluded by default). Results of your jobs are downloaded back |
| Your project's files, for a GPU job | Your project folder | Uploaded over SSH to a RunPod GPU pod created for that job (same exclusions, plus `ONESHOT_EXCLUDE`), with a one-time SSH key; the pod and its disk are deleted when the job ends |
| GPU pod records and spend | `logs/runpod/` (until each pod is deleted), `logs/usage.tsv` and `logs/last-gpu` in your cloudmule folder | Nowhere |
| The list of your projects | `registry/` in your cloudmule folder (each project's folder path) | Nowhere |
| Job logs | `logs/` in your cloudmule folder, and on your server | Nowhere else |
| The location of your cloudmule folder | `~/.config/cloudmule/home` | Nowhere |

**Snapshots.** When a session ends (or the server is idle), cloudmule saves the server's whole disk as a snapshot
in your Hetzner account, so the next start is fast. It contains every project you worked on with cloudmule, their
installed dependencies and caches. Only the newest one is kept. It stays until you delete it.

**Downloads on the server.** To prepare your server, it downloads Ubuntu packages, the tools your project needs
(Node.js from nodejs.org, ffmpeg from GitHub, verified by checksum) and your project's own dependencies. These
requests come from your server, as with any build.

**Claude Code.** cloudmule's Claude Code skill asks Claude to run cloudmule's commands. Their output (file names,
logs, prices) appears in your Claude Code conversation, like the output of any command Claude runs.

## Hetzner

Hetzner Online GmbH stores and processes everything you put on your servers and snapshots under its own terms
and privacy policy, as your provider. By default cloudmule only uses locations in the EU (Nuremberg, Falkenstein,
Helsinki); you can change this in `.env` (`LOCATIONS`).

## RunPod

If you use GPU jobs, RunPod (Runpod Inc.) runs your pods and processes what you upload to them under its own terms
and privacy policy, as your provider. cloudmule uses its SECURE cloud. Pods are deleted after each job.

## Deleting your data

- Servers: `cloudmule end <project> --keep` (or `--forget` to also delete the project's folder there); the cost
  guard deletes idle servers on its own. GPU pods are deleted after each job. `cloudmule status` shows what exists.
- Snapshots and the SSH key: delete them in the Hetzner console or with `hcloud image delete` /
  `hcloud ssh-key delete`.
- On your computer: delete the cloudmule folder, `~/.config/cloudmule`, and each project's `.cloudmule/` folder.
  The README's "Uninstall" section lists every step.

## Contact

Questions or concerns: open an issue at https://github.com/BrunoChampion/cloudmule/issues.
