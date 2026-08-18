// browserscan.mjs against the headed Linux Chrome in the container, so the
// reference column comes from the browser the engine claims to be rather than
// from whatever Chrome the host happens to have.
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { withLinuxChrome } from './linux-chrome.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));

await withLinuxChrome(async (endpoint) => {
  await new Promise((resolve, reject) => {
    const p = spawn('node', [path.join(here, 'browserscan.mjs')], {
      stdio: ['ignore', 'inherit', 'inherit'],
      env: { ...process.env, CDP_ENDPOINT: endpoint },
    });
    p.on('close', (c) => (c === 0 ? resolve() : reject(new Error('browserscan.mjs exited ' + c))));
  });
}, { hostPort: 9368 });
