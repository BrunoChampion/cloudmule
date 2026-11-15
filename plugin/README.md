# cloudmule — Claude Code plugin

Your computer edits; a server you rent by the hour does the heavy lifting. This plugin adds the `cloudmule`
skill to **Claude Code**: before running heavy work (dependency installs, builds, test suites, dev servers, test
browsers, video renders), Claude runs it on a Hetzner Cloud server in **your own Hetzner account** and brings the
results back, so your computer stays responsive.

**Claude Code only.** The skill runs commands in a terminal, so it does nothing in Claude's chat or in Cowork.

## What you need besides this plugin

The plugin is only the skill. The work is done by the cloudmule command-line tool, which you install yourself:

1. A Hetzner Cloud account and an API token (Read & Write). Servers cost money while they exist.
2. Clone https://github.com/BrunoChampion/cloudmule, open Claude Code in that folder and say "install cloudmule"
   (or follow its README). Requirements: bash (Git Bash on Windows), ssh, Python 3 and Hetzner's `hcloud` CLI.

Without that, the skill only tells you how to install it. To install the plugin alone, in Claude Code:

```
/plugin install cloudmule --marketplace BrunoChampion/cloudmule
```

(`cloudmule setup` also installs it for you.)

## What the skill does

- Reads `~/.config/cloudmule/home` to find your cloudmule folder, then runs `bash <that folder>/bin/cloudmule …`.
  Claude Code asks for your permission as for any command.
- **Before creating a server** (it bills by the hour), shows you the server types that fit your project and their
  prices, and waits for your choice. It never creates a server without it.
- Uploads your project's files to that server over SSH (except what the project excludes; `.env` files are
  excluded by default), runs the project's jobs there, and downloads their results.
- To set a project up, writes a `.cloudmule/` folder in it (settings and job scripts, never secrets) and a short
  note in its `CLAUDE.md`, after telling you.

## What cloudmule sends, and where

- To the **Hetzner Cloud API**: your token (to manage your servers), your computer's SSH public key, and the
  server and snapshot operations.
- To **your own server**: your project's files, the job scripts, and your Hetzner token in its memory only (a RAM
  disk, never saved to disk or snapshots), so its cost guard can snapshot and delete the server when it is idle.
- **Snapshots** of the server's disk stay in your Hetzner account until you delete them.
- Nothing is sent to the plugin's author or anyone else. No telemetry.

Details: [PRIVACY.md](PRIVACY.md). Source and documentation: https://github.com/BrunoChampion/cloudmule.

Created by Bruno Champion (NYVEX). MIT License.
