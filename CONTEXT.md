# cloudmule

cloudmule rents one Hetzner server by the hour, shared by all of a user's projects, so their own computer only edits.

## Language

**Shared server**:
The single rented server every project of the user works on; it exists only while someone uses it.
_Avoid_: instance, VM, machine

**Lease**:
A project's (or target's) claim on the shared server; the server is deleted only when no lease remains.
_Avoid_: lock, session

**Workspace**:
The snapshot of the whole shared server's disk, saved when it is deleted and restored when it is created again; only the latest is kept.
_Avoid_: image, backup

**Last choice**:
The server type the user last chose for the shared server, with the project whose conversation chose it and when; recorded on Hetzner, so every agent of every project and computer sees it.
_Avoid_: preferred types, default server

**Disk floor**:
The minimum disk size a server must have to restore the workspace: the disk size of the server the workspace was saved from.
_Avoid_: workspace minimum disk, snapshot lock-in

**Provider**:
Where heavy work runs: Hetzner (the shared server, CPU only) or RunPod (GPU pods, only for work that needs a GPU); chosen per project and task, with the user.
_Avoid_: backend, cloud, vendor

**GPU pod**:
A RunPod machine with one GPU, created for one job of one project and deleted when that job ends; never shared, never kept.
_Avoid_: GPU server, instance, worker

**Standing approval**:
The user's explicit permission, recorded in cloudmule's `.env`, to create GPU pods without asking each time, always within the caps there.
_Avoid_: auto-approve, consent

**Context loss**:
The browser dropping a page's WebGL context (a GPU-process reset); three.js then draws on without its canvas textures and environment map, so the pictures come out wrong with no error. cloudmule's WebGL check and watcher look for it.
_Avoid_: GPU crash, black frames

**GPU self-test**:
A job the project names (`GPU_SELFTEST`) that must pass on the pod after the upload and before the real job, e.g. a few frames compared with frames rendered locally; only the project knows what a correct picture looks like.
_Avoid_: smoke test, validation job

**Phase timings**:
How long each step of a GPU run took (catalog, create, boot to SSH, modules, WebGL check, upload, self-test, job, download, delete), printed as one `PHASES` line and kept in `usage.tsv`.
_Avoid_: profile, trace

**Task**:
One independent piece of a job (a chapter or frame range, a file, a batch, a seed, a test shard, a prompt) that can run at the same time as the others on one machine.
_Avoid_: subjob, worker, chunk

**Slots**:
How many of a job's tasks run at once inside one pod (`cloudmule-par --slots N`); chosen from the run's measured GPU, VRAM, CPU and RAM use, to fill one GPU before renting another.
_Avoid_: workers, threads, parallelism
