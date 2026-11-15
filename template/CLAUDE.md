# cloudmule notes for this project

Notes for agents about running this project's heavy work with cloudmule (the `cloudmule` skill has the general
rules). Keep this file up to date when jobs change.

## Jobs (`jobs/`)

| Job | What it does | Results (`CLOUDMULE_RESULT`) |
|---|---|---|
| `example` | prints the server's Node version | `.cloudmule-out/node-version.txt` |

## Settings (`config.sh`)

- What is never uploaded and why; which files are seeds (generated on the server).
- How dependencies are installed and what check confirms it.
- System tools in `server-setup.sh`, if any, and why.

## Reference numbers and known problems

- Real durations, upload/download sizes, server type used, errors already solved.
