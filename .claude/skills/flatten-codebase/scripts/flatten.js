#!/usr/bin/env node
/*
 * flatten.js — Flatten a whole project into a single self-describing text file.
 *
 * The output file embeds a reconstruction PROMPT at the top, so it can be pasted
 * into any AI agent to recreate the project on disk, then built and run.
 *
 * Non-source / build-artifact folders (.venv, .cache, obj, bin, build,
 * node_modules, .dart_tool, .git, ...) and binary files are skipped.
 *
 * Usage (from cmd):
 *   node flatten.js [--root .] [--out flattened_codebase.txt] [--max-kb 1024]
 *                   [--exclude-dir NAME]... [--only-ext .dart,.yaml]
 *                   [--respect-gitignore] [--no-tree]
 */

'use strict';
const fs = require('fs');
const path = require('path');

// ---------------------------------------------------------------------------
// Defaults: folders that are "not meant to be flattened"
// ---------------------------------------------------------------------------
const DEFAULT_EXCLUDE_DIRS = new Set([
  '.git', '.svn', '.hg',
  '.venv', 'venv', 'env', '.env', 'virtualenv',
  '.cache', '__pycache__', '.pytest_cache', '.mypy_cache', '.ruff_cache', '.tox',
  'node_modules', 'bower_components', '.pnpm-store', 'jspm_packages',
  'obj', 'bin', 'build', 'dist', 'out', 'target', 'Debug', 'Release',
  '.gradle', '.dart_tool', '.idea', '.vscode', '.vs', '.fleet',
  '.next', '.nuxt', '.svelte-kit', '.angular', '.astro',
  'coverage', '.nyc_output', '.terraform', '.serverless',
  'Pods', 'DerivedData', '.cxx', 'vendor',
  '.expo', '.parcel-cache', '.turbo', '.cache-loader', '.eggs',
].map((s) => s.toLowerCase()));

// File extensions treated as binary / generated -> skipped.
const BINARY_EXT = new Set([
  '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.ico', '.webp', '.tiff', '.psd',
  '.otf', '.ttf', '.woff', '.woff2', '.eot',
  '.mp3', '.mp4', '.wav', '.avi', '.mov', '.mkv', '.flac', '.ogg', '.webm', '.m4a',
  '.zip', '.tar', '.gz', '.bz2', '.xz', '.rar', '.7z', '.jar', '.war', '.aar', '.apk', '.ipa',
  '.class', '.o', '.obj', '.a', '.lib', '.so', '.dll', '.dylib', '.exe', '.msi',
  '.pyc', '.pyo', '.pdb', '.wasm',
  '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
  '.keystore', '.jks', '.p12', '.pfx', '.cer', '.crt', '.der',
  '.snapshot', '.stamp', '.bin', '.dat', '.db', '.sqlite', '.sqlite3',
  '.ipr', '.iws',
]);

// Specific filenames to always skip.
const SKIP_NAMES = new Set(['.ds_store', 'thumbs.db']);

// Secret-bearing files: skipped by default so the flat file is safe to paste /
// share. Pass --include-secrets to keep them.
function isSecretFile(name) {
  const l = name.toLowerCase();
  if (l === '.env' || l.startsWith('.env.')) return true;
  if (l.endsWith('.pem')) return true;
  if (l === 'id_rsa' || l === 'id_dsa' || l === 'id_ecdsa' || l === 'id_ed25519') return true;
  if (l === 'secrets.json' || l === 'credentials' || l === 'credentials.json') return true;
  return false;
}

// ---------------------------------------------------------------------------
// Arg parsing
// ---------------------------------------------------------------------------
function parseArgs(argv) {
  const opts = {
    root: process.cwd(),
    out: 'flattened_codebase.txt',
    maxKb: 1024,
    excludeDirs: new Set(),
    onlyExt: null,
    respectGitignore: false,
    tree: true,
    includeSecrets: false,
  };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    const next = () => argv[++i];
    switch (a) {
      case '--root': opts.root = path.resolve(next()); break;
      case '--out': opts.out = next(); break;
      case '--max-kb': opts.maxKb = parseInt(next(), 10) || 1024; break;
      case '--exclude-dir': opts.excludeDirs.add(next().toLowerCase()); break;
      case '--only-ext': {
        opts.onlyExt = new Set(
          next().split(',').map((e) => e.trim().toLowerCase())
            .filter(Boolean).map((e) => (e.startsWith('.') ? e : '.' + e))
        );
        break;
      }
      case '--respect-gitignore': opts.respectGitignore = true; break;
      case '--no-tree': opts.tree = false; break;
      case '--include-secrets': opts.includeSecrets = true; break;
      case '-h': case '--help': printHelp(); process.exit(0); break;
      default:
        console.error(`Unknown argument: ${a}`);
        printHelp(); process.exit(2);
    }
  }
  return opts;
}

function printHelp() {
  console.log(`flatten.js — flatten a project into one pasteable file

  --root <path>            Project root to flatten (default: cwd)
  --out <file>             Output file (default: flattened_codebase.txt)
  --max-kb <n>             Skip text files larger than n KB (default: 1024)
  --exclude-dir <name>     Extra folder name to skip (repeatable)
  --only-ext <.a,.b>       Only include these extensions
  --respect-gitignore      Also skip names listed in top-level .gitignore
  --no-tree                Omit the directory tree from the header
  --include-secrets        Include .env / key / credential files (off by default)`);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function looksBinary(buf) {
  const n = Math.min(buf.length, 8000);
  for (let i = 0; i < n; i++) if (buf[i] === 0) return true;
  return false;
}

function loadGitignoreNames(root) {
  const names = new Set();
  try {
    const txt = fs.readFileSync(path.join(root, '.gitignore'), 'utf8');
    for (let line of txt.split(/\r?\n/)) {
      line = line.trim();
      if (!line || line.startsWith('#')) continue;
      line = line.replace(/^\/+/, '').replace(/\/+$/, '');
      if (line && !line.includes('*') && !line.includes('/')) {
        names.add(line.toLowerCase());
      }
    }
  } catch (_) { /* no gitignore */ }
  return names;
}

function detectProject(root, files) {
  const has = (f) => files.includes(f);
  const anyExt = (ext) => files.some((f) => f.endsWith(ext));
  if (has('pubspec.yaml')) {
    return { type: 'Flutter / Dart', build: ['flutter pub get'], run: ['flutter run   # or: dart run'] };
  }
  if (has('package.json')) {
    return { type: 'Node.js', build: ['npm install'], run: ['npm start   # or check package.json "scripts"'] };
  }
  if (has('pyproject.toml') || has('requirements.txt') || has('setup.py')) {
    return {
      type: 'Python',
      build: ['python -m venv .venv', has('requirements.txt') ? 'pip install -r requirements.txt' : 'pip install -e .'],
      run: ['python main.py   # or the project entrypoint'],
    };
  }
  if (has('go.mod')) return { type: 'Go', build: ['go mod download'], run: ['go run .'] };
  if (has('Cargo.toml')) return { type: 'Rust', build: ['cargo build'], run: ['cargo run'] };
  if (has('pom.xml')) return { type: 'Java / Maven', build: ['mvn install'], run: ['mvn exec:java'] };
  if (has('build.gradle') || has('build.gradle.kts')) return { type: 'Gradle', build: ['./gradlew build'], run: ['./gradlew run'] };
  if (anyExt('.csproj') || anyExt('.sln')) return { type: '.NET', build: ['dotnet restore', 'dotnet build'], run: ['dotnet run'] };
  return { type: 'Unknown', build: ['# inspect the project for build steps'], run: ['# inspect the project for the run command'] };
}

// ---------------------------------------------------------------------------
// Walk
// ---------------------------------------------------------------------------
function walk(root, opts, gitignoreNames, outAbs, secretsOut) {
  const results = [];
  const stack = [root];
  while (stack.length) {
    const dir = stack.pop();
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); }
    catch (_) { continue; }
    for (const ent of entries) {
      const abs = path.join(dir, ent.name);
      const lower = ent.name.toLowerCase();
      if (ent.isSymbolicLink()) continue;
      if (ent.isDirectory()) {
        if (DEFAULT_EXCLUDE_DIRS.has(lower) || opts.excludeDirs.has(lower)) continue;
        if (opts.respectGitignore && gitignoreNames.has(lower)) continue;
        stack.push(abs);
        continue;
      }
      if (!ent.isFile()) continue;
      if (SKIP_NAMES.has(lower)) continue;
      if (!opts.includeSecrets && isSecretFile(ent.name)) {
        secretsOut.push(path.relative(root, abs).split(path.sep).join('/'));
        continue;
      }
      if (opts.respectGitignore && gitignoreNames.has(lower)) continue;
      if (path.resolve(abs) === outAbs) continue;
      const ext = path.extname(ent.name).toLowerCase();
      if (opts.onlyExt && !opts.onlyExt.has(ext)) continue;
      if (BINARY_EXT.has(ext)) continue;
      results.push(abs);
    }
  }
  results.sort((a, b) => a.localeCompare(b));
  return results;
}

function buildTree(relPaths) {
  const lines = [];
  const seen = new Set();
  for (const rel of relPaths) {
    const parts = rel.split('/');
    let prefix = '';
    for (let d = 0; d < parts.length; d++) {
      prefix += (d ? '/' : '') + parts[d];
      const isFile = d === parts.length - 1;
      if (seen.has(prefix)) continue;
      seen.add(prefix);
      lines.push('  '.repeat(d) + (isFile ? parts[d] : parts[d] + '/'));
    }
  }
  return lines.join('\n');
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
function main() {
  const opts = parseArgs(process.argv);
  const root = opts.root;
  if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) {
    console.error(`Root is not a directory: ${root}`);
    process.exit(1);
  }
  const outAbs = path.resolve(root, opts.out);
  const gitignoreNames = opts.respectGitignore ? loadGitignoreNames(root) : new Set();

  const skippedSecrets = [];
  const absFiles = walk(root, opts, gitignoreNames, outAbs, skippedSecrets);
  const maxBytes = opts.maxKb * 1024;

  const rootName = path.basename(root) || 'project';
  const topLevelFiles = fs.readdirSync(root).filter((f) => {
    try { return fs.statSync(path.join(root, f)).isFile(); } catch (_) { return false; }
  });
  const proj = detectProject(root, topLevelFiles);

  const out = fs.createWriteStream(outAbs, { encoding: 'utf8' });
  const kept = [];
  const skippedBig = [];
  const skippedBinary = [];

  // We stream file bodies after writing the header, so collect rel paths first.
  const fileEntries = [];
  for (const abs of absFiles) {
    let buf;
    try { buf = fs.readFileSync(abs); } catch (_) { continue; }
    const rel = path.relative(root, abs).split(path.sep).join('/');
    if (buf.length > maxBytes) { skippedBig.push(rel); continue; }
    if (looksBinary(buf)) { skippedBinary.push(rel); continue; }
    fileEntries.push({ rel, text: buf.toString('utf8') });
    kept.push(rel);
  }

  // ---- Header / embedded prompt ----
  const header = `================================================================================
FLATTENED CODEBASE  —  "${rootName}"
================================================================================

INSTRUCTIONS FOR THE AI AGENT READING THIS FILE
------------------------------------------------
This single file contains the complete SOURCE of a project, flattened. Recreate
the project on disk exactly as described, then build and run it.

1. This file is a sequence of file blocks. Each block has the form:

       ##### BEGIN FILE: <relative/path> #####
       <verbatim file content>
       ##### END FILE: <relative/path> #####

2. For every block, create the file at <relative/path> (relative to a new project
   root). Create any parent directories that do not exist.
3. Write the content between the BEGIN and END marker lines EXACTLY — do not
   reformat, re-indent, add comments, fix, or omit anything. Exactly one newline
   immediately before the END marker is a separator added by the flattener and
   is NOT part of the file content; drop that single newline.
4. Use the paths verbatim; they use forward slashes. Do not rename or move files.
5. Do NOT create any files that are not present here. Binary assets and build
   artifacts were intentionally excluded and should be regenerated by the build.
6. After all files are written, follow the BUILD & RUN section below.

PROJECT METADATA
----------------
Root name : ${rootName}
Type      : ${proj.type}
Generated : ${new Date().toISOString()}
Files     : ${kept.length}
Skipped   : ${skippedBinary.length} binary, ${skippedBig.length} over ${opts.maxKb}KB, ${skippedSecrets.length} secret${skippedSecrets.length ? ' (' + skippedSecrets.join(', ') + ' — recreate manually, not in this file)' : ''}

BUILD & RUN
-----------
Build:
${proj.build.map((c) => '  ' + c).join('\n')}
Run:
${proj.run.map((c) => '  ' + c).join('\n')}

${opts.tree ? 'PROJECT TREE\n------------\n' + buildTree(kept) + '\n' : ''}================================================================================
BEGIN FILES
================================================================================

`;
  out.write(header);

  for (const { rel, text } of fileEntries) {
    out.write(`##### BEGIN FILE: ${rel} #####\n`);
    out.write(text);
    // Exactly one separator newline, always. Reconstruct removes exactly this
    // one, so files with or without a trailing newline round-trip losslessly.
    out.write('\n');
    out.write(`##### END FILE: ${rel} #####\n\n`);
  }

  out.end(() => {
    console.log(`Flattened ${kept.length} files -> ${outAbs}`);
    if (skippedBinary.length) console.log(`  skipped ${skippedBinary.length} binary file(s)`);
    if (skippedBig.length) console.log(`  skipped ${skippedBig.length} file(s) over ${opts.maxKb}KB`);
    if (skippedSecrets.length) console.log(`  skipped ${skippedSecrets.length} secret file(s): ${skippedSecrets.join(', ')} (use --include-secrets to keep)`);
    const sizeKb = (fs.statSync(outAbs).size / 1024).toFixed(1);
    console.log(`  output size: ${sizeKb} KB`);
  });
}

main();
