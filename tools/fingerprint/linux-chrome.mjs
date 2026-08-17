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
// Two things about Chrome in a container that cost an afternoon each:
//   * it will not start as root without --no-sandbox;
//   * it IGNORES --remote-debugging-address and always binds loopback, so the
//     only way to reach CDP from the host is to relay the port inside.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const IMAGE = 'lightpanda-fp-linux-chrome';
const CONTAINER_PORT = 9363;

const DOCKERFILE = `FROM --platform=linux/amd64 debian:bookworm-slim
RUN apt-get update \\
    && apt-get install -y --no-install-recommends ca-certificates wget gnupg socat \\
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
google-chrome-stable \\
  --headless=new \\
  --no-sandbox \\
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

/// Build the image if it is not already there. Cached across runs, so only the
/// first call pays for the Chrome download.
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
