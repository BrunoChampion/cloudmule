# Spec 0003 — The server choice lives on Hetzner, never in settings

Status: agreed 2026-11-16, in progress · Scope: the cloudmule repository only.
Vocabulary: see `CONTEXT.md` (shared server, workspace, disk floor, **last choice**).

## Problem Statement

The type of the shared server can be decided in three places that no agent sees as a whole: `SERVER_TYPES` in
cloudmule's `.env` (per computer: "cx53 cpx62", where CX53 is never available, so in practice a CPX62), an
optional `SERVER_TYPES` in each project's `.cloudmule/config.sh` (YouTube: "ccx33 cpx42 cpx52"), and the
`--type` the user chose in a conversation. `start` without `--type` and every `oneshot` (which has no `--type`)
silently create the first fitting type of those lists. A choice the user made in one project's conversation is
invisible to the agent of another project, or on another computer, once the server is deleted.

The user wants the type chosen in conversation with the agent, and that choice (and any later change) visible to
every agent of every project, folder and computer.

## Solution

1. **No setting chooses a server.** `SERVER_TYPES` disappears from `.env`, from projects' `config.sh` and from the
   code. Creating the shared server always needs `--type`, in `start` and in `oneshot`. Joining a running server
   needs none.
2. **The choice is recorded on Hetzner**, the one place every agent already reads: the server is created with the
   labels `chosen-type`, `chosen-by` (the project whose conversation chose it) and `chosen-at` (date). The
   workspace snapshot copies them when it is saved (`end --keep` and the cost guard), so they outlive the server.
3. **Every agent sees the last choice.** With the server running, its type is the current choice (and `start`
   says who chose it). With it off, `servers` prints `Last choice: <type> (by <project>, <date>)` above the table
   and marks that row; refusals to create without `--type` repeat it.
4. **The user still confirms every creation.** The skill proposes the last choice (or the recommendation) and
   waits for the user's yes, as before: spending money needs the user's choice.

## User Stories

1. As a user, I want no hidden setting to pick a server for me, so that every server I pay for is one I chose.
2. As a user working in a second project, I want its agent to know what I chose in the first project's
   conversation, so that it proposes the same server instead of starting the decision from scratch.
3. As a user on another computer, I want the same: the choice travels with my Hetzner account.
4. As a user, I want to change my mind at the next creation, and that new choice to become the one every agent
   sees.
5. As a user with an old `SERVER_TYPES` in a project or in `.env`, I want to be told it is ignored.

## Implementation Decisions

- **Labels** (Hetzner label values: up to 63 chars of `[A-Za-z0-9._-]`, alphanumeric at both ends):
  `chosen-type=<type>`, `chosen-by=<project, sanitised>`, `chosen-at=<YYYY-MM-DD>`. Set by `create_server` from
  `start --type` / `oneshot --type`. `end --keep` copies the server's `chosen-*` labels onto the snapshot; the
  cost guard (`remote/guard.py`) does the same through the API before its own snapshot.
- **Reading the last choice:** from the running server's labels, else from the newest workspace snapshot's labels;
  "none yet" when neither has them (servers and snapshots made before this spec).
- **`start`**: creating without `--type` (also with `--dry-run`) refuses: `NEEDS_SERVER_TYPE: … Last choice: …`.
  `--dry-run` with `--type` also prints `WOULD_LABEL: chosen-type=… chosen-by=… chosen-at=…`. Joining prints
  `chosen by <project> on <date>` (inside the server's type parentheses) when the server has the labels.
- **`oneshot <project> [target] [--type t] [--location l] <job> [args…]`**: options before the job name. Creating
  without `--type` refuses like `start`, before anything is created.
- **`servers`**: a `Last choice:` line before the table (when no server runs); the fitting row of that type ends
  with `(last choice)`. The "Preferred types" text goes.
- **`setup`** no longer prints prices of `SERVER_TYPES`: it checks the token with one read call and points to
  `cloudmule servers`.
- **Old settings:** `SERVER_TYPES` in `.env` or a project's `config.sh` is ignored with a one-line note. The
  template and `.env.example` lose it.
- **Skill:** with the server off, relay the last choice and propose it or the recommendation; wait for the
  user's yes; `start`/`oneshot … --type <chosen>`.
- Plugin version 0.3.0.
- After the code review (2026-11-16): `chosen-by` is trimmed to start and end with a letter or digit (a project
  named `foo-` is recorded as `foo`); the `(last choice)` mark goes only on a fitting row, at its end, and only
  when no server runs; `oneshot` also accepts `--fresh` (documented); `setup`'s old `price` helper is gone; the
  docs no longer say `setup` prints prices.

## Testing Decisions

Through the CLI with the fake `hcloud` (fixtures get `chosen-*` labels on the running server and the workspace):
`start` without `--type` refuses with the last choice; `--dry-run --type` prints `WOULD_LABEL`; `servers` shows
the last choice and marks its row, or "none yet" without labels; joining shows who chose; `end --keep` copies
the labels onto the snapshot; `oneshot` without `--type` refuses and with a non-fitting `--type` gives
`NO_FITTING_SERVER` (proving the option is parsed), never creating a server; a project's `SERVER_TYPES` prints the
"ignored" note; a setting from the environment still wins over `.env` (tested with `LOCATIONS`). The guard's
label copy runs only on a real server: e2e checklist.

## Out of Scope

- Changing the type of a running server (Hetzner's rescale). The choice changes at the next creation.
- Reusing the last choice without asking the user.

## Further Notes

- Written 2026-11-16 after the user asked to remove `SERVER_TYPES` and keep the choice global. State: plugin
  0.2.0 installed; branch `disk-floor-and-usage` with specs 0002 (done) and this one; the running server (CPX62)
  and the workspace (snapshot 457207116) have no `chosen-*` labels yet, so the first menu will say "none yet".
