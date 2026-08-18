// A real Linux Chrome to measure against, from a macOS host.
//
// Chrome ships no arm64 Linux build, so this runs the official amd64 package
// under docker's linux/amd64 emulation. That sounds like it should invalidate
// the numbers and does not: the canonical audio render captured this way came
// out byte-for-byte identical to the same container on a native x86-64 Xeon
// (see tools/fingerprint/README.md, `## G21`), even though the two report
// different CPU features. Verify again before trusting it for a surface that
// is more CPU-sensitive than this one.
//
// It runs *headed*, under Xvfb, rather than with --headless=new. That costs an
// X server in the image and is not optional for a detector baseline: some of
// these sites treat headless Chrome differently on purpose, so a headless Linux
// reference would swap the macOS-vs-Linux confound for a headed-vs-headless one
// and the sweep would still be measuring two things at once. What it does NOT
// buy is a GPU -- WebGL is SwiftShader either way (see the `## G21` P4 table).
//
// Three things about Chrome in a container that cost an afternoon each:
//   * it will not start as root without --no-sandbox;
//   * it IGNORES --remote-debugging-address and always binds loopback, so the
//     only way to reach CDP from the host is to relay the port inside;
//   * headed Chrome needs a display, and it needs one that exists *before* it
//     starts -- `xvfb-run` handles both.
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const IMAGE_NAME = 'lightpanda-fp-linux-chrome';
const CONTAINER_PORT = 9363;

const DOCKERFILE = `FROM --platform=linux/amd64 debian:bookworm-slim
RUN apt-get update \\
    && apt-get install -y --no-install-recommends ca-certificates wget gnupg socat xvfb xauth \\
    && wget -q -O /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \\
    && apt-get install -y --no-install-recommends /tmp/chrome.deb \\
    && rm -f /tmp/chrome.deb \\
    && rm -rf /var/lib/apt/lists/*
RUN useradd -m -s /bin/bash chrome
COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh
USER chrome
WORKDIR /home/chrome
EXPOSE ${CONTAINER_PORT}
CMD ["/usr/local/bin/start.sh"]
`;

const START_SH = `#!/bin/sh
set -e
xvfb-run -a --server-args="-screen 0 1920x1080x24" \\
google-chrome-stable \\
  --no-sandbox \\
  --window-size=1920,1080 \\
  --disable-dev-shm-usage \\
  --remote-debugging-port=9362 \\
  --user-data-dir=/home/chrome/prof \\
  --no-first-run \\
  --no-default-browser-check \\
  about:blank &
i=0
while [ ! -f /home/chrome/prof/DevToolsActivePort ] && [ $i -lt 120 ]; do
  i=$((i + 1))
  sleep 1
done
exec socat TCP-LISTEN:${CONTAINER_PORT},fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:9362
`;

const run = (cmd, args, opts = {}) =>
  new Promise((resolve, reject) => {
    const p = spawn(cmd, args, { stdio: ['ignore', 'pipe', 'pipe'], ...opts });
    let out = '';
    let err = '';
    p.stdout.on('data', (d) => (out += d));
    p.stderr.on('data', (d) => (err += d));
    p.on('error', reject);
    p.on('close', (code) => (code === 0 ? resolve(out.trim()) : reject(new Error(`${cmd} ${args.join(' ')} failed (${code}):\n${err}`))));
  });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// The tag carries a hash of the two files that define the image, so editing them
// builds a new image instead of silently reusing the old one. A fixed tag plus a
// "does it exist" check made a Dockerfile change a no-op -- which is how you end
// up measuring a headless Chrome you thought you had switched to headed.
const IMAGE = `${IMAGE_NAME}:${crypto.createHash('sha256').update(DOCKERFILE + START_SH).digest('hex').slice(0, 12)}`;

/// Build the image if it is not already there. Cached across runs, so only the
/// first call pays for the Chrome download -- and only when the recipe is
/// unchanged, because the tag is content-addressed.
export async function buildImage({ rebuild = false } = {}) {
  if (!rebuild) {
    const existing = await run('docker', ['images', '-q', IMAGE]).catch(() => '');
    if (existing) return IMAGE;
  }
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'lp-linux-chrome-'));
  try {
    await fs.writeFile(path.join(dir, 'Dockerfile'), DOCKERFILE);
    await fs.writeFile(path.join(dir, 'start.sh'), START_SH);
    await run('docker', ['build', '--platform', 'linux/amd64', '-t', IMAGE, dir]);
  } finally {
    await fs.rm(dir, { recursive: true, force: true }).catch(() => {});
  }
  return IMAGE;
}

/// Start a Linux Chrome, hand its CDP endpoint to `fn`, and always tear it down.
export async function withLinuxChrome(fn, { hostPort = 9363 } = {}) {
  await buildImage();
  const name = `lp-fp-linux-chrome-${hostPort}`;
  await run('docker', ['rm', '-f', name]).catch(() => {});
  await run('docker', [
    'run', '-d', '--rm', '--name', name,
    '--platform', 'linux/amd64',
    '-p', `127.0.0.1:${hostPort}:${CONTAINER_PORT}`,
    IMAGE,
  ]);
  try {
    const endpoint = `http://127.0.0.1:${hostPort}`;
    let version = null;
    for (let i = 0; i < 180; i++) {
      try {
        version = await (await fetch(`${endpoint}/json/version`)).json();
        break;
      } catch {
        await sleep(1000);
      }
    }
    if (!version) throw new Error('Linux Chrome never answered on CDP');
    return await fn(endpoint, version);
  } finally {
    await run('docker', ['rm', '-f', name]).catch(() => {});
  }
}
