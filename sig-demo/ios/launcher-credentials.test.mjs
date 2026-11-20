// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, symlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { readBraveCredential } from './launcher-credentials.mjs';

function fixture(run) {
  const directory = mkdtempSync(join(tmpdir(), 'sig-ios-brave-'));
  try { run(directory); }
  finally { rmSync(directory, { recursive: true, force: true }); }
}

test('reuses a quoted exported desktop credential', () => fixture(directory => {
  const path = join(directory, 'brave.env');
  writeFileSync(path, '# local fixture\nexport BRAVE_SEARCH_API_KEY="synthetic-brave-private"\n', { mode: 0o600 });
  assert.equal(readBraveCredential(path), 'synthetic-brave-private');
}));

test('missing optional credential remains optional but explicit selection fails', () => fixture(directory => {
  const path = join(directory, 'absent.env');
  assert.equal(readBraveCredential(path), undefined);
  assert.throws(() => readBraveCredential(path, { required: true }), /unavailable or invalid/);
}));

test('ambiguous and invalid credentials fail without exposing their contents', () => fixture(directory => {
  const path = join(directory, 'brave.env');
  for (const contents of [
    'BRAVE_SEARCH_API_KEY=synthetic-first\nBRAVE_SEARCH_API_KEY=synthetic-second\n',
    'BRAVE_SEARCH_API_KEY="synthetic secret with spaces"\n',
    'BRAVE_SEARCH_API_KEY=\n',
    'BRAVE_SEARCH_API_KEY=' + 'x'.repeat(1025) + '\n',
    'BRAVE_SEARCH_API_KEY=synthetic-🚀\n',
  ]) {
    writeFileSync(path, contents, { mode: 0o600 });
    assert.throws(() => readBraveCredential(path), error => {
      assert.equal(error.message, 'The selected desktop Brave search credential is unavailable or invalid.');
      assert.ok(!error.message.includes('synthetic'));
      return true;
    });
  }
}));

test('symlinks cannot redirect the credential read', () => fixture(directory => {
  const path = join(directory, 'brave.env');
  const link = join(directory, 'link.env');
  writeFileSync(path, 'BRAVE_SEARCH_API_KEY=synthetic-private\n', { mode: 0o600 });
  symlinkSync(path, link);
  assert.throws(() => readBraveCredential(link), /unavailable or invalid/);
}));
