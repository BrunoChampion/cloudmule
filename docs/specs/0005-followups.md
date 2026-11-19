# Spec 0005 — follow-ups: improvements and problems left for later

Status: recorded 2026-11-19 at the owner's request, after implementing spec 0005. The owner accepted the measured
results as they are (below) and asked to keep the improvements and the problems seen on the way here, to apply them
another time. Nothing here is decided yet: each item says what was measured, what to try, and roughly what it is worth.
Vocabulary: `CONTEXT.md`. Numbers: spec 0005, Further Notes.

## Targets accepted as they are

| Spec target | Measured (A40 SECURE) | Status |
|---|---|---|
| Step (a): command → job start ≤ 3 min | ~8 min (443 s without the self-test), modules 332 s on a crawling Ubuntu mirror; after the mirror fix only the modules were re-measured (125 s): est. 3.5–4 min | missed, superseded by step (b) |
| Step (b): command → job start ≤ 1.5 min | 80 s to the project's self-test; 122 s to the job counting the 42-s self-test | accepted (missed by 32 s with the self-test) |
| User story 5: a 38-s Short in < 7 min, command → MP4 | 6 min 59 s (one run, prebuilt image) | met at the edge, one sample |
| e2e 2: near-linear gain up to 6 slots on the render load | measured on a synthetic GPU-bound load: 1× / 2.7× / 3.7× | not measured on the real render |

## Improvements to try

1. **Shorten the time to the job (step b).** What is left before the job, from the e2e with the image: SSH 36 s,
   WebGL check 16 s, upload 20 s (80.9 MB from the owner's computer), self-test 42 s (the project's).
   - Run the WebGL check while the upload runs (the check needs no project files). The spec puts the check "before
     the upload" so a broken GPU uploads nothing; overlapping keeps that only if the upload is cancelled when the
     check fails. Worth ~15 s.
   - Upload less: the Short Form project sends 80.9 MB; its `SYNC_EXCLUDE`/`ONESHOT_EXCLUDE` are the project's to
     tune (assets the render does not read). Worth up to ~20 s.
   - A shorter self-test is the project's choice (fewer frames, fewer samples): today 4 frames at 10 samples, 42 s.
   - WebGL check: 8 s of drawing is the spec's minimum before the job; Chrome's start adds ~6 s.
2. **Measure the image's cold pull.** The first pod with the image (`o0fstfc6flwuf3`) never showed SSH in 300 s; the
   second reached SSH in 36 s. The cause (a first pull of 1.14 GB from GHCR on that host) is not proven. Measure the
   pull on a few cold hosts; if it is slow, consider building the image FROM `runpod/pytorch` (its base layers are
   likely cached on RunPod's hosts, so only cloudmule's layers are pulled), or a smaller image. The boot allowance is
   600 s meanwhile (it bills while waiting).
3. **e2e 2 on the real render.** Run `cloudmule-par` with 1 / 3 / 6 slots on the Short Form long video's chapters (or
   equal frame ranges) once that project's jobs use `cloudmule-par`; the real load is CPU-bound (x264 and JPEG on the
   pod's 7.65 vCPUs), so the gain will be lower than the synthetic 3.7×.
4. **More vCPUs per GPU.** Still open: whether `POST /pods` accepts a vCPU count per GPU (`minVcpuCount`/`vcpuCount`)
   and what it costs. CPU-bound renders would gain most. Check RunPod's API docs and price first; never send the field
   blind.
5. **Image rebuild cadence.** Chrome is pinned only by the image digest; nothing reminds anyone to rebuild when Chrome
   needs updating. A monthly rebuild (push a `gpu-image-<date>` tag), or a `gpus`/`gpu` note when the image is older
   than N weeks.
6. **e2e for `cuda` with a real project.** e2e 3 used a small PyTorch probe (fine for the watcher and the slots rule);
   repeat with a real inference/training project when one exists.

## Problems seen, and code to tidy

- **Fragile environment, fixed on the way (keep in mind):** Python's `urllib` tried IPv6 first (42 s per RunPod
  call); `archive.ubuntu.com` crawls from RunPod's hosts (33 kB/s; pods use `RUNPOD_APT_MIRROR`); editing
  `bin/cloudmule` while a cloudmule command runs breaks that command at its end; the test suite's fake `ssh` treated any
  command containing "tar … xf" as an upload and hung when stdin stayed open (pattern tightened; run the suite with
  `< /dev/null`).
- **`cloudmule-par` on the shared Hetzner server** comes with the `base` module, which is reinstalled once where its
  marker predates `cloudmule-par` (a one-time apt run on the restored workspace).
- **Image hash scope:** `images/gpu-graphics/modules-hash.py` hashes all of `remote/modules`, including modules the
  image does not contain (`python.sh`), so an unrelated module edit fails `tests/run.sh` until the image is rebuilt
  and its digest committed. Hash only the image's modules plus `lib/`.
- **Duplicated logic:** `images/gpu-graphics/install-modules.sh` repeats `module_apt` and the one-apt-pass flow of
  `bin/lib.sh`; `gpu-summary --last` repeats `gpu_use_line`'s formatting. Share them.
- **Structure:** the `gpu)` case in `bin/cloudmule` is ~150 lines (lock, budget loop, phases, self-test, deadline,
  verdict); `[ "$NEEDS_GPU" = graphics ]` is tested in six places; the `POD\t…` line has 8 positional fields with `-`
  placeholders (a `key=value` line would be sturdier); `PHASES` is built in three ways.
- **Tests not written:** the local watchdog (`rp-reap --after`) using `--max-minutes`; the remote wait giving up after
  15 failed looks when a pod disappears; `apt-pass.sh`'s mirror switch and fallback (it edits `/etc/apt` directly).
- **Monthly cap and records:** it reads `usage.tsv`, so `USAGE_KEEP_DAYS` must stay ≥ 31 (now enforced); cloudmule's
  costs are estimates — compare with RunPod's billing now and then.
- **GitHub Actions:** the pinned actions run on Node 20 (deprecated, forced to Node 24 by GitHub); bump them by SHA.
  `workflow_dispatch` only works once the workflow is on the default branch; until then build from a tag.
