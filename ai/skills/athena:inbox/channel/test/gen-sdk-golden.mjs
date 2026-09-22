#!/usr/bin/env node
// gen-sdk-golden.mjs -- record the SDK<->shim wire golden (DND-283 ruling 1a).
//
// NEEDS node_modules: run `npm ci` in the channel dir first. The captain runs
// this ONCE in its worktree; its OUTPUT (test/sdk-golden.json) is COMMITTED and
// replayed hermetically by test/sdk-conformance.mjs. The harness gate never
// runs this file (it has no node_modules).
//
// What it does: drives server.mjs with the PINNED @modelcontextprotocol/sdk
// Client through a byte-capturing tee (tee-stdio.mjs), performs the real
// initialize / initialized / tools-list / ping handshake, drives ONE channel
// event via a fake inbox-status (unread>0) received through the SDK's own
// notification parser, then writes the recorded frames + the SDK's version and
// protocol constants to test/sdk-golden.json.
//
// Usage: node test/gen-sdk-golden.mjs   (after: npm ci)
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import {
  NotificationSchema,
  LATEST_PROTOCOL_VERSION,
  SUPPORTED_PROTOCOL_VERSIONS,
} from '@modelcontextprotocol/sdk/types.js';
import { z } from 'zod';
import { readFileSync, writeFileSync, mkdtempSync, rmSync, closeSync, openSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';

const HERE = dirname(fileURLToPath(import.meta.url)); // .../channel/test
const CHANNEL = dirname(HERE); // .../channel
const SERVER = join(CHANNEL, 'server.mjs');
const TEE = join(HERE, 'tee-stdio.mjs');
const GOLDEN = join(HERE, 'sdk-golden.json');

function die(msg, fix) {
  process.stderr.write(`gen-sdk-golden: ${msg}\n  Fix: ${fix}\n`);
  process.exit(1);
}

// The SDK version actually installed (the pinned tree npm ci resolved).
let sdkVersion;
try {
  const sdkPkg = JSON.parse(
    readFileSync(join(CHANNEL, 'node_modules', '@modelcontextprotocol', 'sdk', 'package.json'), 'utf8'),
  );
  sdkVersion = sdkPkg.version;
} catch {
  die('the @modelcontextprotocol/sdk package is not installed', 'run `npm ci` in the channel dir, then re-run this generator.');
}

// A private capture file + fakes so the shim confirms tenancy and emits exactly
// one channel event, with NO real registry, inbox, or network touched.
const tmp = mkdtempSync(join(tmpdir(), 'sdk-golden-'));
const capture = join(tmp, 'capture.ndjson');
const fakeStatus = join(tmp, 'fake-status.sh');
const fakeResolve = join(tmp, 'fake-resolve.sh');
const fakeWait = join(tmp, 'fake-wait.sh');
writeFileSync(
  fakeStatus,
  '#!/usr/bin/env bash\n' +
    `printf '%s' '{"channels":[{"name":"peer-mail","kind":"maildir","unread":1,"count":1}],"failed_candidates":0,"repo_key":"/tmp/golden/.git"}'\n`,
  { mode: 0o755 },
);
writeFileSync(fakeResolve, '#!/usr/bin/env bash\necho golden-project\n', { mode: 0o755 });
// The doorbell fs-watch will watch must exist, or arming fails and the shim
// emits `stopped` instead of the genuine unread wake we want in the golden.
closeSync(openSync(join(tmp, '.event'), 'a'));
writeFileSync(
  fakeWait,
  '#!/usr/bin/env bash\n' +
    `[ "\${1:-}" = "--dry-run" ] && { echo "${tmp}/.event"; exit 0; }\nexec sleep 3\n`,
  { mode: 0o755 },
);

const env = {
  ...process.env,
  ATHENA_TEE_CAPTURE: capture,
  ATHENA_INBOX_STATUS_BIN: fakeStatus,
  ATHENA_INBOX_RESOLVE_PROJECT_BIN: fakeResolve,
  ATHENA_INBOX_WAIT_BIN: fakeWait,
  ATHENA_CHANNEL_WATCH_MODE: 'fs-watch',
};
delete env.ATHENA_INBOX_EXPECT_PROJECT;

const transport = new StdioClientTransport({ command: 'node', args: [TEE, SERVER], env, stderr: 'inherit' });
const client = new Client({ name: 'athena-sdk-golden', version: '1.0.0' });

const channelSchema = NotificationSchema.extend({ method: z.literal('notifications/claude/channel') });
const notifications = [];
client.setNotificationHandler(channelSchema, (n) => {
  notifications.push(n);
});

await client.connect(transport);
await client.listTools();
await client.ping();

const deadline = Date.now() + 5000;
while (notifications.length === 0 && Date.now() < deadline) {
  await new Promise((r) => setTimeout(r, 100));
}
await client.close();
await new Promise((r) => setTimeout(r, 200)); // let the tee flush its last append

if (notifications.length === 0) {
  rmSync(tmp, { recursive: true, force: true });
  die('no channel notification arrived through the SDK parser', 'confirm the fake inbox-status emits unread>0 and the shim reached startup catch-up.');
}

const lines = readFileSync(capture, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
const clientFrames = lines.filter((x) => x.dir === 'client').map((x) => x.frame);
const serverFrames = lines.filter((x) => x.dir === 'server').map((x) => x.frame);
const byId = (frames, id) => frames.find((f) => f.id === id);

const clientInitialize = clientFrames.find((f) => f.method === 'initialize');
const serverInitializeResult = clientInitialize && byId(serverFrames, clientInitialize.id);
const clientInitialized = clientFrames.find((f) => f.method === 'notifications/initialized');
const clientToolsList = clientFrames.find((f) => f.method === 'tools/list');
const serverToolsListResult = clientToolsList && byId(serverFrames, clientToolsList.id);
const clientPing = clientFrames.find((f) => f.method === 'ping');
const serverPingResult = clientPing && byId(serverFrames, clientPing.id);
const channelNotification = serverFrames.find((f) => f.method === 'notifications/claude/channel');

const frames = {
  clientInitialize,
  serverInitializeResult,
  clientInitialized,
  clientToolsList,
  serverToolsListResult,
  clientPing,
  serverPingResult,
  channelNotification,
};
for (const [name, frame] of Object.entries(frames)) {
  if (!frame) {
    rmSync(tmp, { recursive: true, force: true });
    die(`did not capture the ${name} frame`, 'the handshake did not complete as expected; inspect the capture NDJSON before committing a partial golden.');
  }
}

const golden = { sdkVersion, LATEST_PROTOCOL_VERSION, SUPPORTED_PROTOCOL_VERSIONS, frames };
writeFileSync(GOLDEN, JSON.stringify(golden, null, 2) + '\n');
rmSync(tmp, { recursive: true, force: true });
process.stdout.write(`gen-sdk-golden: wrote ${GOLDEN} from sdk ${sdkVersion}\n`);
