---
name: flatten-codebase
description: >-
  Flatten an entire project/codebase into a single portable text file that
  embeds a reconstruction prompt, so it can be pasted into any AI agent to
  recreate the project on disk, then build and run it. Skips build artifacts and
  non-source folders (.venv, .cache, obj, bin, build, node_modules, .dart_tool,
  .git, etc.) and binary files. Use when the user asks to "flatten a codebase",
  "put the whole project into one file", "export project to a single file to
  paste to an agent", or "reconstruct a project from a flattened file".
---

# Flatten Codebase

Turn a whole project into **one self-describing text file** (source only, no build
junk) that carries its own instructions. Paste that file to any agent and it will
recreate the project on disk, ready to build and run. A reverse script rebuilds the
project locally without an agent.

Runs on **Node.js via `cmd`** (PowerShell is not used in this environment).

## Files in this skill

- `scripts/flatten.js` — walk a project, skip non-source/build dirs and binaries,
  emit a single flat file with an embedded reconstruction prompt + build/run hints.
- `scripts/reconstruct.js` — parse a flat file and recreate the project on disk.

## How to flatten (the common case)

Run from the project root (or pass `--root`):

```
node .claude\skills\flatten-codebase\scripts\flatten.js --root . --out flattened_codebase.txt
```

Then give `flattened_codebase.txt` to the user, or open it and copy its contents to
paste into another agent. The top of the file already contains the full prompt that
tells the receiving agent exactly how to rebuild every file — no extra explanation
needed.

Parameters:

- `--root <path>` — project to flatten (default: current directory).
- `--out <file>` — output file (default: `flattened_codebase.txt`).
- `--max-kb <n>` — skip text files larger than this (default: 1024).
- `--exclude-dir <name>` — additional folder name to skip (repeatable).
- `--only-ext <.a,.b>` — restrict to specific extensions (e.g. `--only-ext .dart,.yaml`).
- `--respect-gitignore` — also skip names listed in the top-level `.gitignore`.
- `--no-tree` — omit the directory tree from the header.
- `--include-secrets` — keep `.env` / key / credential files (off by default).

What is skipped by default (the "not meant to be flattened" set):

- Dirs: `.git .svn .hg .venv venv env .cache __pycache__ .pytest_cache .mypy_cache
  node_modules bower_components obj bin build dist out target .gradle .dart_tool
  .idea .vscode .vs .next .nuxt .svelte-kit coverage .terraform Pods DerivedData
  .cxx vendor .expo .turbo` (and more — see `flatten.js`).
- Binary/generated files by extension (images, fonts, archives, compiled objects,
  media, certs, snapshots, databases) and any file that contains NUL bytes.
- Secret files (`.env`, `.env.*`, `*.pem`, `id_rsa`, `credentials`, ...) so the
  flat file is safe to paste/share. They are listed in the header so the agent
  knows to recreate them manually. Override with `--include-secrets`.
- Files above the size limit, and the output file itself.

The header also auto-detects the project type (Flutter, Node, Python, Go, Rust,
Java/Maven, Gradle, .NET) and writes the matching **build & run** commands.

## How to reconstruct locally (bonus / verification)

```
node .claude\skills\flatten-codebase\scripts\reconstruct.js --in flattened_codebase.txt --dest .\restored --force
```

Only needed if you want to rebuild without pasting to an agent, or to verify the
flat file round-trips correctly.

## Guidance

- Run flatten from a clean checkout so build artifacts are minimal; the excludes
  handle the rest.
- If the flat file is huge, tighten scope with `--only-ext` or add `--exclude-dir`
  rather than raising the size limit.
- The embedded prompt already instructs the agent to create parent dirs, write exact
  content, not invent files, and then run the build/run commands. Do not re-explain
  the format — it is in the file.
- To verify a round trip: flatten, `reconstruct.js` into a temp dir, then diff
  against the source.
