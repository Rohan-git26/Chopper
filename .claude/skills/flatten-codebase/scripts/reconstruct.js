#!/usr/bin/env node
/*
 * reconstruct.js — Rebuild a project on disk from a file produced by flatten.js.
 *
 * This is the local equivalent of pasting the flattened file into an agent.
 * Useful for verifying a round trip, or rebuilding without an agent.
 *
 * Usage (from cmd):
 *   node reconstruct.js --in flattened_codebase.txt [--dest ./restored] [--force]
 */

'use strict';
const fs = require('fs');
const path = require('path');

function parseArgs(argv) {
  const opts = { input: null, dest: path.resolve('restored'), force: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    const next = () => argv[++i];
    switch (a) {
      case '--in': case '--input': opts.input = next(); break;
      case '--dest': opts.dest = path.resolve(next()); break;
      case '--force': opts.force = true; break;
      case '-h': case '--help':
        console.log('reconstruct.js --in <flat file> [--dest ./restored] [--force]');
        process.exit(0);
        break;
      default:
        console.error(`Unknown argument: ${a}`);
        process.exit(2);
    }
  }
  if (!opts.input) { console.error('Missing --in <flattened file>'); process.exit(2); }
  return opts;
}

const BEGIN_RE = /^##### BEGIN FILE: (.+) #####$/m;
const END_RE = /^##### END FILE: (.+) #####$/m;

function main() {
  const opts = parseArgs(process.argv);
  const raw = fs.readFileSync(opts.input, 'utf8');
  const lines = raw.split('\n');

  let i = 0;
  let count = 0;
  while (i < lines.length) {
    const beginMatch = lines[i].match(BEGIN_RE);
    if (!beginMatch) { i++; continue; }
    const rel = beginMatch[1].trim();
    i++;
    const body = [];
    while (i < lines.length && !END_RE.test(lines[i])) {
      body.push(lines[i]);
      i++;
    }
    // Skip the END marker line.
    if (i < lines.length) i++;

    // The flattener always wrote exactly one separator newline before the END
    // marker. Splitting on '\n' turns that separator into the line boundary
    // between the content and the END marker, so joining the collected lines
    // reproduces the original content byte-for-byte (with or without a trailing
    // newline).
    const content = body.join('\n');

    const target = path.join(opts.dest, rel);
    const norm = path.resolve(target);
    if (!norm.startsWith(path.resolve(opts.dest) + path.sep) && norm !== path.resolve(opts.dest)) {
      console.error(`Refusing path outside dest: ${rel}`);
      continue;
    }
    if (fs.existsSync(target) && !opts.force) {
      console.error(`Exists (use --force to overwrite): ${rel}`);
      continue;
    }
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, content, 'utf8');
    count++;
  }

  console.log(`Reconstructed ${count} file(s) into ${opts.dest}`);
  if (count === 0) {
    console.error('No file blocks found — is this a flatten.js output file?');
    process.exit(1);
  }
}

main();
