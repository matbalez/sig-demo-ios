#!/usr/bin/env node
// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import { spawnSync } from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  copyFileSync,
} from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { publicClientConfiguration } from './public-client-config.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const lock = JSON.parse(
  readFileSync(path.join(here, 'upstream.lock.json'), 'utf8')
);
const flags = process.argv.slice(2);
let checkout = path.join(root, '.sig-demo/ios/chatgpt/Signal-iOS');
let configPath;
let checkOnly = false;

function fail(message) {
  throw new Error(message);
}

function run(args, options = {}) {
  const result = spawnSync('git', args, {
    cwd: root,
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    ...options,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    const detail = (
      result.stderr ||
      result.stdout ||
      `exit status ${result.status}`
    ).trim();
    fail(`git ${args[0]} failed: ${detail}`);
  }
  return result.stdout;
}

function git(args, options) {
  return run(['-C', checkout, ...args], options);
}

function normalizedPatch(value) {
  // A generated public configuration changes the destination blob ID, without
  // changing the reviewed patch structure. Git apply does not require that ID.
  return value.replace(/^index [a-f0-9]+\.\.[a-f0-9]+(?: \d+)?\n/gm, '');
}

try {
  for (let index = 0; index < flags.length; index += 1) {
    const flag = flags[index];
    if (flag === '--check') {
      checkOnly = true;
    } else if (flag === '--config' || flag === '--checkout') {
      const value = flags[++index];
      if (!value || value.startsWith('--')) fail(`${flag} requires a path.`);
      if (flag === '--config') configPath = path.resolve(value);
      else checkout = path.resolve(value);
    } else {
      fail(`Unknown option: ${flag}`);
    }
  }
  if (!configPath) {
    fail(
      'Pass --config with the explicit public desktop client JSON. There is no default backend.'
    );
  }
  const client = publicClientConfiguration(
    JSON.parse(readFileSync(configPath, 'utf8'))
  );
  const embedded = Buffer.from(JSON.stringify(client)).toString('base64');
  const template = lock.patches
    .map(name => readFileSync(path.join(here, name), 'utf8'))
    .join('');
  if (template.split('__SIG_DEMO_CLIENT_CONFIGURATION_BASE64__').length !== 2) {
    fail(
      'The reviewed isolation patch must have exactly one public configuration placeholder.'
    );
  }
  let patch = template.replace(
    '__SIG_DEMO_CLIENT_CONFIGURATION_BASE64__',
    embedded
  );
  for (const [placeholder, directory] of [
    ['__SIG_DEMO_NATIVE_AGENT_PACKAGE_PATH__', 'NativeAgent'],
    ['__SIG_DEMO_KIT_PACKAGE_PATH__', 'SigDemoKit'],
    ['__SIG_DEMO_MESH_PACKAGE_PATH__', 'Mesh'],
    ['__SIG_DEMO_PAID_MESH_PACKAGE_PATH__', 'PaidMesh'],
  ]) {
    if (patch.split(placeholder).length !== 2)
      fail(
        'The reviewed patch must contain each native package path exactly once.'
      );
    patch = patch.replaceAll(
      placeholder,
      path.relative(checkout, path.join(here, directory))
    );
  }

  const overlays = [];
  function collectOverlays(directory, prefix = '') {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const name = path.join(prefix, entry.name);
      if (entry.isDirectory())
        collectOverlays(path.join(directory, entry.name), name);
      else if (entry.isFile() && name.endsWith('.swift')) overlays.push(name);
    }
  }
  collectOverlays(path.join(here, 'overlays'));

  if (!existsSync(checkout)) {
    if (checkOnly)
      fail('The pinned Signal iOS checkout has not been prepared.');
    mkdirSync(path.dirname(checkout), { recursive: true });
    run(
      [
        'clone',
        '--filter=blob:none',
        '--no-checkout',
        lock.repository,
        checkout,
      ],
      { stdio: 'inherit' }
    );
    git(['fetch', '--depth', '1', 'origin', `refs/tags/${lock.tag}`], {
      stdio: 'inherit',
    });
    git(['checkout', '--detach', lock.commit], { stdio: 'inherit' });
  }
  const head = git(['rev-parse', 'HEAD']).trim();
  if (head !== lock.commit) {
    fail(
      `Expected Signal iOS ${lock.tag} (${lock.commit}); checkout is ${head}. Local changes were preserved.`
    );
  }
  if (
    readFileSync(path.join(checkout, '.xcode-version'), 'utf8').trim() !==
    `Xcode ${lock.xcode}`
  ) {
    fail(
      'The upstream Xcode requirement differs from the reviewed source pin.'
    );
  }

  const diff = git([
    'diff',
    '--no-ext-diff',
    '--binary',
    'HEAD',
    '--',
    '.',
    ':!Pods',
  ]);
  const untracked = git(['ls-files', '--others', '--exclude-standard'])
    .trim()
    .split('\n')
    .filter(Boolean);
  if (untracked.some(name => !overlays.includes(name)))
    fail(
      'The source checkout has untracked files. Local files were preserved.'
    );
  const alreadyApplied = normalizedPatch(diff) === normalizedPatch(patch);
  if (diff && !alreadyApplied) {
    fail(
      'The source checkout contains other edits or a different backend configuration. Local changes were preserved; prepare another checkout with --checkout.'
    );
  }
  if (!alreadyApplied) {
    if (checkOnly)
      fail('The reviewed private-demo isolation patch has not been applied.');
    git(['apply', '--check', '-'], { input: patch });
    git(['apply', '-'], { input: patch });
  }
  for (const relative of overlays) {
    const source = path.join(here, 'overlays', relative);
    const destination = path.join(checkout, relative);
    if (existsSync(destination)) {
      if (!readFileSync(source).equals(readFileSync(destination))) {
        fail(
          `The native overlay ${relative} has other edits. Local changes were preserved.`
        );
      }
    } else {
      if (checkOnly) fail(`Missing native source ${relative}.`);
      mkdirSync(path.dirname(destination), { recursive: true });
      copyFileSync(source, destination);
    }
  }

  console.log(
    `${checkOnly ? 'Verified' : 'Prepared'} Signal iOS ${lock.tag} at ${checkout}`
  );
  console.log(
    `App ID: ${lock.bundleIdPrefix}.signal; Xcode ${lock.xcode}; iOS ${lock.iosDeploymentTarget}+.`
  );
  console.log(
    'Native invite signup and ChatGPT Sig integration are prepared. Build the private libsignal bridge and native agent before compiling the app.'
  );
} catch (error) {
  console.error(`sig demo iOS: ${error.message}`);
  process.exitCode = 1;
}
