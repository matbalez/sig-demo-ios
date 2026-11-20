// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Compile the actual pure status policy from the shipping service, so this
// regression does not need Signal, a wallet, network access, or credentials.
const here = path.dirname(fileURLToPath(import.meta.url));
const source = readFileSync(path.join(here, 'overlays/Signal/SigDemo/SigDemoAgentService.swift'), 'utf8');
const begin = '// BEGIN SIG_DEMO_PAID_CONNECTION_STATUS';
const end = '// END SIG_DEMO_PAID_CONNECTION_STATUS';
if (source.split(begin).length !== 2 || source.split(end).length !== 2) {
  throw new Error('The shipping paid connection status policy could not be located uniquely.');
}
const policy = source.slice(source.indexOf(begin) + begin.length, source.indexOf(end));
const temporary = mkdtempSync(path.join(os.tmpdir(), 'sig-demo-paid-status-'));
try {
  const helper = path.join(temporary, 'Status.swift');
  const binary = path.join(temporary, 'status-tests');
  const inputs = [helper, path.join(here, 'PaidMesh/Sources/SigDemoPaidMesh/PaidMeshTypes.swift'),
    path.join(here, 'test-paid-connection-status.swift')];
  writeFileSync(helper, 'import Foundation\n' + policy, { mode: 0o600 });
  execFileSync('xcrun', ['swiftc', '-swift-version', '6', '-module-cache-path', path.join(temporary, 'ModuleCache'),
    '-parse-as-library', ...inputs, '-o', binary], { stdio: 'inherit' });
  execFileSync(binary, [], { stdio: 'inherit' });
  if (process.argv.includes('--ios')) {
    for (const [sdkName, target] of [['iphonesimulator', 'arm64-apple-ios16.0-simulator'], ['iphoneos', 'arm64-apple-ios16.0']]) {
      const sdk = execFileSync('xcrun', ['--sdk', sdkName, '--show-sdk-path'], { encoding: 'utf8' }).trim();
      execFileSync('xcrun', ['swiftc', '-swift-version', '6', '-typecheck', '-parse-as-library', '-target', target,
        '-sdk', sdk, '-module-cache-path', path.join(temporary, sdkName + '-ModuleCache'), ...inputs], { stdio: 'inherit' });
    }
    console.log('Paid connection status: iOS 16 device and simulator typechecks passed');
  }
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
