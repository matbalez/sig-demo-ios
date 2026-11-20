// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import assert from 'node:assert/strict';
import { rootCertificates } from 'node:tls';
import test from 'node:test';
import { approvedRelayHost, publicClientConfiguration } from './public-client-config.mjs';

function client() {
  const endpoint = 'https://localhost:14443';
  const publicValue = Buffer.alloc(32, 1).toString('base64');
  return {
    sigDemoEnabled: true,
    sigDemoNetworkMode: 'localhost',
    updatesEnabled: false,
    storageProfile: 'demo',
    serverUrl: endpoint,
    storageUrl: `${endpoint}/storageService`,
    sfuUrl: `${endpoint}/callingService`,
    registrationChallengeUrl: `${endpoint}/disabled`,
    challengeUrl: `${endpoint}/disabled`,
    updatesUrl: `${endpoint}/disabled`,
    resourcesUrl: `${endpoint}/updates2`,
    contentProxyUrl: `${endpoint}/disabled`,
    cdn: { 0: endpoint, 2: endpoint, 3: `${endpoint}/cdn3` },
    certificateAuthority: rootCertificates[0],
    serverTrustRoots: [Buffer.alloc(33, 1).toString('base64')],
    serverPublicParams: publicValue,
    genericServerPublicParams: publicValue,
    backupServerPublicParams: publicValue,
  };
}

test('copies public identities and excludes invitations and inference secrets', () => {
  const config = client();
  config.inviteCode = 'do-not-embed';
  config.meshPaid = { inviteToken: 'do-not-embed' };
  config.OPENAI_API_KEY = 'do-not-embed';
  const output = publicClientConfiguration(config);
  assert.equal(output.serverUrl, config.serverUrl);
  assert.equal(output.serverPublicParams, config.serverPublicParams);
  assert.equal(JSON.stringify(output).includes('do-not-embed'), false);
});

test('retains only an approved opaque TLS relay and explicit demo flags', () => {
  const config = client();
  config.sigDemoRelay = {
    host: approvedRelayHost,
    port: 8443,
    inviteCode: 'never-copy',
  };
  const output = publicClientConfiguration(config);
  assert.deepEqual(output.sigDemoRelay, { host: approvedRelayHost, port: 8443 });
  assert.equal(output.sigDemoEnabled, true);
  assert.equal(output.sigDemoNetworkMode, 'localhost');
  assert.equal(output.updatesEnabled, false);
  assert.equal(output.storageProfile, 'demo');
  for (const relay of [
    { host: 'chat.signal.org', port: 443 },
    { host: approvedRelayHost, port: 0 },
    { host: approvedRelayHost, port: 8443.5 },
  ]) {
    assert.throws(() =>
      publicClientConfiguration({ ...config, sigDemoRelay: relay })
    );
  }
});

test('rejects production/staging and inconsistent service routes', () => {
  for (const key of [
    'serverUrl',
    'storageUrl',
    'sfuUrl',
    'registrationChallengeUrl',
    'challengeUrl',
    'updatesUrl',
    'resourcesUrl',
    'contentProxyUrl',
  ]) {
    for (const value of [
      'https://chat.signal.org',
      'https://chat.staging.signal.org',
      'https://localhost:15555',
      'http://localhost:14443',
      'https://secret@localhost:14443',
    ]) {
      const config = client();
      // A different server port is valid when every endpoint matches it; the
      // fixture deliberately keeps the remaining service routes unchanged.
      config[key] = value;
      assert.throws(
        () => publicClientConfiguration(config),
        undefined,
        `${key}: ${value}`
      );
    }
  }
  const config = client();
  config.cdn[3] = 'https://cdn3.signal.org';
  assert.throws(() => publicClientConfiguration(config));
  for (const suffix of [
    '/../storageService',
    '/%2e%2e/storageService',
    '/foo\\bar',
    '/foo\nbar',
  ]) {
    const unsafe = client();
    unsafe.storageUrl = `https://localhost:14443${suffix}`;
    assert.throws(() => publicClientConfiguration(unsafe));
  }
});

test('requires isolated mode, disabled updater, CA, and public identity material', () => {
  for (const [key, value] of [
    ['sigDemoEnabled', false],
    ['sigDemoNetworkMode', 'production'],
    ['updatesEnabled', true],
    ['storageProfile', 'production'],
    ['certificateAuthority', 'invalid'],
    ['serverTrustRoots', []],
    ['serverTrustRoots', [Buffer.alloc(32, 1).toString('base64')]],
    ['serverTrustRoots', ['BXu6QIKVz5MA8gstzfOgRQGqyLqOwNKHL6INkv3IHWMF']],
    ['serverTrustRoots', ['BUkY0I+9+oPgDCn4+Ac6Iu813yvqkDr/ga8DzLxFxuk6']],
    ['serverTrustRoots', ['BbqY1DzohE4NUZoVF+L18oUPrK3kILllLEJh2UnPSsEx']],
    ['serverTrustRoots', ['BYhU6tPjqP46KGZEzRs1OL4U39V5dlPJ/X09ha4rErkm']],
    ['serverPublicParams', 'invalid'],
    ['genericServerPublicParams', ''],
    ['backupServerPublicParams', null],
  ]) {
    const config = client();
    config[key] = value;
    assert.throws(() => publicClientConfiguration(config), undefined, key);
  }
});
