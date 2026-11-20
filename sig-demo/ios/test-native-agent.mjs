// Copyright 2026 sig demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

// Real Swift -> UniFFI -> Rust Goose -> synthetic HTTP SSE. No Mesh process,
// payment, wallet, Brave request, or external model request is made.
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { createServer } from 'node:http';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const execute = promisify(execFile);
const ios = fileURLToPath(new URL('.', import.meta.url));
const workspace = resolve(ios, '../..');
const native = join(ios, 'NativeAgent');
const generated = join(native, 'Generated');
const output = join(workspace, '.sig-demo/ios/swift-smoke');
const library = join(
  workspace,
  '.sig-demo/ios/agent-build/aarch64-apple-darwin/release'
);
assert.ok(
  existsSync(join(generated, 'module.modulemap')),
  'Run build-native-agent.sh first.'
);
assert.ok(
  existsSync(join(library, 'libsig_demo_agent.dylib')),
  'Build the macOS agent first.'
);
mkdirSync(output, { recursive: true });

const executable = join(output, 'native-agent-smoke');
await execute('swiftc', [
  '-swift-version',
  '6',
  '-parse-as-library',
  '-D',
  'SIG_DEMO_AGENT_TESTING',
  '-module-cache-path',
  join(output, 'module-cache'),
  '-I',
  generated,
  '-L',
  library,
  '-lsig_demo_agent',
  join(generated, 'sig_demo_agent.swift'),
  join(native, 'Sources/SigDemoAgent/ChatGPTSigAgent.swift'),
  join(native, 'Smoke.swift'),
  '-o',
  executable,
]);

const validations = [];
const sockets = new Set();
const credentialMarkers = [
  'synthetic-launcher-key-never-send',
  'synthetic-ambient-key-never-send',
  'synthetic-key-never-send',
  'synthetic-brave-key-never-send',
];
let completions = 0;
let cancellations = 0;
const server = createServer(async (request, response) => {
  try {
    let input = '';
    for await (const chunk of request) input += chunk;
    const body = JSON.parse(input);
    assert.equal(request.url, '/v1/chat/completions');
    assert.equal(request.headers.authorization, undefined);
    assert.equal(request.headers['x-mesh-target'], undefined);
    for (const marker of credentialMarkers) assert.ok(!input.includes(marker));
    assert.equal(body.stream, true);
    assert.equal(body.parallel_tool_calls, false);
    assert.deepEqual(body.chat_template_kwargs, { enable_thinking: false });
    if (['swift-search-capable', 'swift-hosted-search-capable'].includes(body.model)) {
      assert.equal(body.tools.length, 1);
      assert.equal(body.tools[0].function.name, 'brave_web_search');
    } else {
      assert.ok(!body.tools?.length, 'Mesh without a search credential advertised tools.');
    }
    assert.ok(!input.includes('local-account-secret'));
    assert.ok(!input.includes('local-chat-secret'));
    assert.ok(!input.includes('local-query-'));
    assert.ok(!input.includes('local-response-'));
    response.writeHead(200, { 'content-type': 'text/event-stream' });
    if (body.model === 'swift-cancel') {
      response.flushHeaders();
      response.on('close', () => {
        cancellations += 1;
      });
      return;
    }
    assert.ok(['swift-fixture', 'swift-search-capable', 'swift-hosted-search-capable'].includes(body.model));
    completions += 1;
    for (const [delta, finish] of [
      [{ content: 'Native Swift ' }, null],
      [{ content: 'answer.' }, null],
      [{}, 'stop'],
    ]) {
      response.write(
        `data: ${JSON.stringify({ model: body.model, choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`
      );
    }
    response.end('data: [DONE]\n\n');
  } catch (error) {
    validations.push(error);
    response.writeHead(500).end();
  }
});
server.on('connection', socket => {
  sockets.add(socket);
  socket.on('close', () => sockets.delete(socket));
});
await new Promise(resolveReady => server.listen(0, '127.0.0.1', resolveReady));
try {
  // A credential-free child proves the shipping Mesh initializer needs no
  // OpenAI environment value. The second child proves ambient credentials do
  // not enter the Mesh HTTP headers/body. No real provider keys are inherited.
  for (const mode of ['no-openai-key', 'synthetic-ambient-key']) {
    const smokeEnvironment = { DYLD_LIBRARY_PATH: library };
    for (const name of ['PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG']) {
      if (process.env[name] !== undefined)
        smokeEnvironment[name] = process.env[name];
    }
    if (mode === 'synthetic-ambient-key') {
      smokeEnvironment.SIG_DEMO_OPENAI_API_KEY = credentialMarkers[0];
      smokeEnvironment.OPENAI_API_KEY = credentialMarkers[1];
    }
    const { stdout } = await execute(
      executable,
      [`http://127.0.0.1:${server.address().port}/v1`, mode],
      { timeout: 30_000, env: smokeEnvironment }
    );
    process.stdout.write(stdout);
  }
  assert.deepEqual(validations, []);
  assert.equal(completions, 10);
  assert.ok(cancellations >= 4);
} finally {
  for (const socket of sockets) socket.destroy();
  await new Promise(resolveClosed => server.close(resolveClosed));
}
