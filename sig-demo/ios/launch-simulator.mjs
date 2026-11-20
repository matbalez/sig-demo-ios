#!/usr/bin/env node
// Copyright 2026 sig demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import { execFile } from 'node:child_process';
import { readFileSync, mkdirSync, openSync, closeSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { readBraveCredential } from './launcher-credentials.mjs';

const execute = promisify(execFile);
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const usage =
  'Use --device UDID [--app PATH] [--invite-file PATH --display-name NAME] [--agent-key-file PATH | --without-agent-key] [--brave-key-file PATH | --without-brave-key] [--test-prompt TEXT] [--log-dir PATH].';
if (process.argv.includes('--help')) {
  console.log(usage);
  process.exit(0);
}
const options = {};
for (let index = 2; index < process.argv.length; index += 1) {
  const flag = process.argv[index];
  if (flag === '--without-agent-key' || flag === '--without-brave-key') {
    options[flag.slice(2)] = true;
    continue;
  }
  const value = process.argv[++index];
  if (
    ![
      '--device',
      '--app',
      '--invite-file',
      '--display-name',
      '--agent-key-file',
      '--brave-key-file',
      '--test-prompt',
      '--log-dir',
    ].includes(flag) ||
    !value ||
    value.startsWith('--')
  ) {
    throw new Error(usage);
  }
  options[flag.slice(2)] = value;
}
if (options['without-agent-key'] && options['agent-key-file'])
  throw new Error('Choose either --without-agent-key or --agent-key-file.');
if (options['without-brave-key'] && options['brave-key-file'])
  throw new Error('Choose either --without-brave-key or --brave-key-file.');
if (!options.device)
  throw new Error(
    'Choose an explicit isolated demo simulator with --device UDID.'
  );
let appPath = options.app;
if (!appPath) {
  try {
    appPath = JSON.parse(
      readFileSync(
        resolve(root, '.sig-demo/ios/chatgpt/Build/simulator-app.json'),
        'utf8'
      )
    ).appPath;
  } catch {
    throw new Error(
      'Build and stage the simulator app first with build-app.sh, or pass a signed simulator bundle using --app.'
    );
  }
  if (
    typeof appPath !== 'string' ||
    !appPath.startsWith('/private/tmp/sig-demo-ios-simulator-')
  ) {
    throw new Error(
      'The simulator staging receipt is invalid. Run build-app.sh again.'
    );
  }
}
const app = resolve(root, appPath);
const { stdout: identifier } = await execute('/usr/libexec/PlistBuddy', [
  '-c',
  'Print :CFBundleIdentifier',
  `${app}/Info.plist`,
]);
const bundleID = identifier.trim();
if (bundleID !== 'dev.matbalez.sig-demo.ios.signal') {
  throw new Error(
    'This launcher only installs the separately identified native sig demo app.'
  );
}
const { stdout: platform } = await execute('/usr/libexec/PlistBuddy', [
  '-c',
  'Print :CFBundleSupportedPlatforms:0',
  `${app}/Info.plist`,
]);
if (platform.trim() !== 'iPhoneSimulator') {
  throw new Error('Choose the isolated iPhoneSimulator app bundle.');
}
await execute('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);

let apiKey;
if (!options['without-agent-key'])
  try {
    const contents = readFileSync(
      resolve(root, options['agent-key-file'] ?? '.sig-demo/agent.env'),
      'utf8'
    );
    const match = /^\s*(?:export\s+)?OPENAI_API_KEY\s*=\s*([^\r\n]*)/m.exec(
      contents
    );
    const candidate = match?.[1].trim().replace(/^(['"])(.*)\1$/, '$2');
    if (candidate && candidate.length >= 12) apiKey = candidate;
  } catch {
    // Public Mesh does not need an OpenAI key. An explicitly selected key file
    // remains an error if it cannot be read or has no usable credential.
  }
if (options['agent-key-file'] && !apiKey)
  throw new Error('The explicitly selected OpenAI credential is unavailable.');
const braveKey = options['without-brave-key'] ? undefined : readBraveCredential(
  resolve(root, options['brave-key-file'] ?? '.sig-demo/brave.env'),
  { required: Boolean(options['brave-key-file']) }
);
const env = { ...process.env };
delete env.SIMCTL_CHILD_SIG_DEMO_OPENAI_API_KEY;
delete env.SIMCTL_CHILD_SIG_DEMO_BRAVE_SEARCH_API_KEY;
if (apiKey) env.SIMCTL_CHILD_SIG_DEMO_OPENAI_API_KEY = apiKey;
if (braveKey) env.SIMCTL_CHILD_SIG_DEMO_BRAVE_SEARCH_API_KEY = braveKey;
let invitation;
if (options['invite-file']) {
  try {
    invitation = JSON.parse(
      readFileSync(resolve(root, options['invite-file']), 'utf8')
    ).inviteCode;
  } catch {
    throw new Error(
      'The private invite file must contain a valid JSON invitation record.'
    );
  }
  if (
    typeof invitation !== 'string' ||
    invitation.length < 20 ||
    !options['display-name']
  ) {
    throw new Error(
      'The private invite file and test display name are required for automatic test enrollment.'
    );
  }
  env.SIMCTL_CHILD_SIG_DEMO_INVITE_CODE = invitation;
  env.SIMCTL_CHILD_SIG_DEMO_DISPLAY_NAME = options['display-name'];
}
if (options['test-prompt'])
  env.SIMCTL_CHILD_SIG_DEMO_TEST_PROMPT = options['test-prompt'];

try {
  const logOptions = [];
  if (options['log-dir']) {
    const directory = resolve(root, options['log-dir']);
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    const name = `sig-demo-${Date.now()}-${randomUUID()}`;
    for (const stream of ['stdout', 'stderr']) {
      const destination = resolve(directory, `${name}.${stream}.log`);
      closeSync(openSync(destination, 'wx', 0o600));
      logOptions.push(`--${stream}=${destination}`);
      console.log(`Simulator ${stream}: ${destination}`);
    }
  }
  await execute('xcrun', ['simctl', 'bootstatus', options.device, '-b']);
  await execute('xcrun', ['simctl', 'install', options.device, app]);
  const { stdout } = await execute(
    'xcrun',
    [
      'simctl',
      'launch',
      '--terminate-running-process',
      ...logOptions,
      options.device,
      bundleID,
    ],
    { env }
  );
  process.stdout.write(stdout);
  console.log(
    apiKey
      ? 'The reused inference key was supplied only in the simulator launch environment.'
      : 'No ChatGPT credential was supplied. Public Mesh remains available in Sig agent settings.'
  );
  console.log(braveKey
    ? 'The reused Brave credential was supplied only in the simulator launch environment for local GDK search.'
    : 'No Brave credential was supplied. Local Mesh web search is unavailable.');
} catch (error) {
  let message = error.stderr || error.message || 'Simulator launch failed.';
  for (const secret of [apiKey, braveKey, invitation].filter(Boolean))
    message = message.replaceAll(secret, '<redacted>');
  console.error(message);
  process.exitCode = 1;
}
