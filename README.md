# cloudmule

**Your computer edits. A rented server does the heavy lifting.**

cloudmule runs the heavy work of your projects (dependency installs, builds, test suites, dev servers, test
browsers, video renders) on a [Hetzner Cloud](https://www.hetzner.com/cloud) server rented **by the hour**, and
brings the results back. It is made to be driven by [Claude Code](https://claude.com/claude-code): a skill tells
your agents when and how to use it, in every project.

It exists because a 16 GB laptop running a browser, an editor and several AI coding agents runs out of memory
the moment one of them starts a build. With cloudmule, that build runs on a 16 vCPU / 32 GB server for about
€0.06–0.21 per hour, and the laptop stays responsive.

```
 your computer                                    Hetzner (your account)
┌──────────────────────────┐   upload changes   ┌───────────────────────────────┐
│ project A  .cloudmule/   │ ─────────────────▶ │ one shared server             │
│ project B  .cloudmule/   │                    │  /root/work/project-a         │
│ Claude Code + skill      │ ◀───────────────── │  /root/work/project-b         │
│ cloudmule/ (.env, keys)  │   download results │  cost guard: deletes itself   │
└──────────────────────────┘                    │  when idle (snapshot first)   │
                                                └───────────────────────────────┘
```

## How it works

- **One server for all your projects.** It is created when you need it, shared by every project, and
  **deleted** when nobody uses it. Its disk is saved as a snapshot first, so the next start has everything
  already installed and uploaded.
- **Only what changed travels.** Uploads compare file sizes and dates; jobs announce which files to bring back.
- **Each project carries its own settings** in a `.cloudmule/` folder: what the server must have installed,
  what never to upload, how to install dependencies, and one script per heavy task. No secrets ever go there.
- **It can't run up a bill by itself.** A guard on the server deletes it after 45 idle minutes or 8 hours, even
  if your computer is off. Creating a server always needs your confirmation.
- **Work that needs a GPU goes to [RunPod](https://www.runpod.io) instead** (optional): WebGL/three.js frames
  rendered in headless Chrome, CUDA. One GPU pod per job, created, used and **deleted**; Hetzner has no GPUs, and
  on a CPU such renders fall back to software, ~20× slower than a laptop. Your agent picks the provider from the
  project's settings and asks you what it doesn't know.

## Requirements

- A Hetzner Cloud account and an API token (Read & Write).
- `bash`, `ssh`, `tar` and Python 3: built in on macOS and Linux; on Windows, [Git for Windows](https://gitforwindows.org/) (Git Bash) and Python 3.
- [`hcloud`](https://github.com/hetznercloud/cli), Hetzner's official CLI (Windows: `winget install --id HetznerCloud.CLI --exact --source winget`, macOS: `brew install hcloud`).
- Optional, for GPU work: a RunPod account with credit and an API key that can manage pods and has "catalog read"
  permission (RunPod → Settings → API Keys), pasted into `.env` as `RUNPOD_API_KEY`.
- Claude Code, for the skill (cloudmule also works by hand without it).

Tested on Windows 11 with Git Bash. macOS and Linux should work (plain bash), but are not tested yet.

## Install

1. Clone this repository wherever you like:
   ```sh
   git clone https://github.com/BrunoChampion/cloudmule.git
   ```
2. Open Claude Code in that folder and say **"install cloudmule"**. It walks you through the rest. Or by hand:
   ```sh
   cp .env.example .env        # paste your Hetzner token into .env (never into a chat)
   bash bin/cloudmule setup    # checks the token, creates this computer's SSH key, installs the Claude Code plugin
   ```
3. Start a new Claude Code session. The `cloudmule` skill is now available in all your projects.
   (`setup` installs it for you. To install it from Claude Code instead, in one command:
   `/plugin install cloudmule --marketplace BrunoChampion/cloudmule`. The skill still needs this folder, set up
   with your token: it is what talks to Hetzner.)

`setup` also writes one file outside this folder, `~/.config/cloudmule/home`, holding this folder's location
so the skill can find it. Moved the folder? Run `setup` again.

## Use

In any project, ask Claude Code for heavy work ("run the test suite", "build the app") or say **"set up
cloudmule here"**. The first time, the skill looks at the project, writes its `.cloudmule/` settings and jobs,
and asks whether to commit them. After that:

```sh
cloudmule servers my-app                  # what you can rent now, what fits the project, €/h (free)
cloudmule start my-app --type cpx42       # creates the server you chose (or joins the running one)
cloudmule job   my-app test       # uploads changes, runs .cloudmule/jobs/test.sh there, downloads results
cloudmule end   my-app --keep     # snapshot + delete the server (unless another project is using it)
cloudmule status                  # what exists and bills right now
cloudmule usage my-app            # what each job used (peak RAM, cores, time), to pick a server size (free)
```

(`cloudmule` here means `bash <cloudmule-folder>/bin/cloudmule`.) Run `cloudmule help` for every command.

For work that needs a GPU (the project says `NEEDS_GPU=graphics` or `cuda` in `.cloudmule/config.sh`):

```sh
cloudmule gpus my-video                                   # GPUs available now, USD/h, worst case, caps (free)
cloudmule gpu  my-video --gpu "NVIDIA A40" --approved render   # one pod: set up, upload, run, download, DELETE
```

## What it costs

- **Servers:** you choose the size each time one is created: `cloudmule servers` shows every type available now
  that fits your project (from 2 vCPU / 4 GB at about €0.01/h to 48 vCPU / 192 GB), shared or dedicated CPUs,
  with prices and your last choice (recorded on Hetzner, so every project sees it). Billed per started hour while
  the server exists. No setting picks a server for you.
- **Mind the disk floor:** a saved workspace only restores on a disk at least as large as the one it came from;
  `cloudmule servers` shows which choices raise it. `cloudmule start … --fresh` starts over from a clean system
  when you want to go smaller.
- **Snapshots:** about €0.01 per GB per month for the saved workspace (dependencies and caches make it grow).
- `cloudmule usage` shows what each job really used (peak RAM, cores), to pick the size with evidence.
- **GPU pods (RunPod):** billed while they exist; the GPUs usually available within the default cap cost about
  0.57–0.70 USD/h (measured: a 10-minute video rendered on an A40 at 0.59 USD/h is about 0.11 USD). Hard limits in `.env`, enforced by cloudmule even
  when you approve each pod: `RUNPOD_MAX_USD_PER_HOUR` (0.70), `RUNPOD_MAX_MINUTES` per pod (40) and
  `RUNPOD_MAX_USD_PER_DAY` (2.00). Every pod is deleted when its job ends, by a watchdog on your computer, and by
  a guard inside the pod even if your computer is off. You approve each pod, unless you give your agent a
  standing approval (`RUNPOD_STANDING_APPROVAL=1`), always within those limits. `cloudmule usage` shows what each
  GPU job cost.

## Security

- **Your Hetzner token** stays in `.env` on your computer (git-ignored). On the server it only exists in memory
  (`/run/cloudmule/token`), so it is never saved in a snapshot. Prefer one token per computer.
- **Your RunPod key** (optional) also stays in `.env`; it is never sent to a pod (a pod deletes itself with its
  own pod-scoped credentials). Each pod gets a one-time SSH key, deleted with it.
- **Access to the server** is by SSH key only: one key per computer, registered in your Hetzner account.
- **Your code is uploaded** to a server and snapshots in your Hetzner account. Exclude what must never leave
  your computer with `SYNC_EXCLUDE` (`.env` files are excluded by default).
- **A project's `.cloudmule/`** holds only commands and settings; cloudmule refuses to run if it finds files
  that look like secrets there.
- cloudmule only talks to Hetzner through the official `hcloud` CLI, and to RunPod through its REST API.
- No backend and no telemetry: nothing is sent to the author or anyone but Hetzner (and RunPod, for GPU
  jobs). Full details in
  [PRIVACY.md](PRIVACY.md).

## Uninstall

```sh
cloudmule status                                   # make sure no server or GPU pod is running
hcloud image list -l managed-by=cloudmule          # delete snapshots you no longer want: hcloud image delete <id>
hcloud ssh-key delete cloudmule-<computer-name>
claude plugin uninstall cloudmule@cloudmule && claude plugin marketplace remove cloudmule
rm -rf ~/.config/cloudmule <cloudmule-folder>      # and each project's .cloudmule/ if you want
```

## Limitations

- Linux servers only: no iOS builds (they need macOS) and probably no Android emulator (no KVM).
- One shared server: projects working at the same time share its CPU and RAM.
- GPU pods: NVIDIA only, RunPod's SECURE cloud only (its COMMUNITY pods have no public SSH), one GPU per pod, and
  cheap GPUs are often unavailable. Each pod installs Chrome and the project's tools again (~2 min).

## Contributing

`bash tests/run.sh` runs the test suite: it needs no Hetzner or RunPod account and spends nothing (it fakes the
Hetzner CLI, RunPod's API and the SSH to pods). Releases are also checked by hand with [`docs/e2e-checklist.md`](docs/e2e-checklist.md).

## Credits

Created by **Bruno Champion** at **[NYVEX](https://nyvex.dev)**. Released under the [MIT License](LICENSE).
