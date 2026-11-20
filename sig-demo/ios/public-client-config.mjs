// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import { X509Certificate } from 'node:crypto';
import { readFileSync } from 'node:fs';

export const approvedRelayHost = readFileSync(
  new URL('./SigDemoKit/Sources/SigDemoKit/Resources/ApprovedRelay.txt', import.meta.url),
  'utf8'
).trim();

const endpointKeys = [
  'storageUrl',
  'sfuUrl',
  'registrationChallengeUrl',
  'challengeUrl',
  'updatesUrl',
  'resourcesUrl',
  'contentProxyUrl',
];
const parameterKeys = [
  'serverPublicParams',
  'genericServerPublicParams',
  'backupServerPublicParams',
];
const signalServiceRoots = new Set([
  // Both production and staging roots from the pinned Signal iOS source.
  'BXu6QIKVz5MA8gstzfOgRQGqyLqOwNKHL6INkv3IHWMF',
  'BUkY0I+9+oPgDCn4+Ac6Iu813yvqkDr/ga8DzLxFxuk6',
  'BbqY1DzohE4NUZoVF+L18oUPrK3kILllLEJh2UnPSsEx',
  'BYhU6tPjqP46KGZEzRs1OL4U39V5dlPJ/X09ha4rErkm',
]);

function requireBase64(value, name) {
  if (
    typeof value !== 'string' ||
    !/^[A-Za-z0-9+/]+={0,2}$/.test(value) ||
    Buffer.from(value, 'base64').length < 16 ||
    Buffer.from(value, 'base64').toString('base64') !== value
  ) {
    throw new Error(`Invalid public sig demo ${name}.`);
  }
  return value;
}

function requireEndpoint(value, name, origin) {
  if (
    typeof value !== 'string' ||
    /[\s\x00-\x1f\\%]/.test(value) ||
    /(?:^|\/)\.{1,2}(?:\/|$)/.test(value)
  ) {
    throw new Error(`Missing private sig demo ${name}.`);
  }
  const url = new URL(value);
  if (
    url.protocol !== 'https:' ||
    url.hostname !== 'localhost' ||
    !url.port ||
    Number(url.port) === 0 ||
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    (origin && url.origin !== origin)
  ) {
    throw new Error(
      `sig demo ${name} must use the configured https://localhost:<port> TLS relay.`
    );
  }
  return url;
}

// Copy only public server identities. Unknown fields, especially invite and
// inference credentials, are never embedded into the iOS source payload.
export function publicClientConfiguration(input) {
  if (
    !input ||
    typeof input !== 'object' ||
    Array.isArray(input) ||
    input.sigDemoEnabled !== true ||
    input.sigDemoNetworkMode !== 'localhost' ||
    input.updatesEnabled !== false ||
    input.storageProfile !== 'demo'
  ) {
    throw new Error(
      'An explicit isolated sig demo backend configuration is required.'
    );
  }
  const server = requireEndpoint(input.serverUrl, 'serverUrl');
  if (server.pathname !== '/') {
    throw new Error('sig demo serverUrl must have a root path.');
  }
  const output = {
    sigDemoEnabled: true,
    sigDemoNetworkMode: 'localhost',
    updatesEnabled: false,
    storageProfile: 'demo',
    serverUrl: server.origin,
  };
  if (input.sigDemoRelay !== undefined) {
    const relay = input.sigDemoRelay;
    if (
      !relay ||
      typeof relay.host !== 'string' ||
      relay.host.length === 0 ||
      ![approvedRelayHost, 'localhost', '127.0.0.1'].includes(relay.host) ||
      !Number.isInteger(relay.port) ||
      relay.port < 1 ||
      relay.port > 65535
    ) {
      throw new Error(
        'The relay must target the approved private demo server.'
      );
    }
    output.sigDemoRelay = { host: relay.host, port: relay.port };
  }
  for (const key of endpointKeys) {
    output[key] = requireEndpoint(input[key], key, server.origin).href;
  }
  output.disabledUrl = `${server.origin}/disabled`;
  output.cdn = {};
  for (const index of ['0', '2', '3']) {
    output.cdn[index] = requireEndpoint(
      input.cdn?.[index],
      `cdn.${index}`,
      server.origin
    ).href;
  }
  if (typeof input.certificateAuthority !== 'string') {
    throw new Error('The private demo CA certificate is required.');
  }
  const certificate = new X509Certificate(input.certificateAuthority);
  if (!certificate.ca) {
    throw new Error('sig demo requires its own CA certificate.');
  }
  output.certificateAuthority = certificate.toString();
  if (
    !Array.isArray(input.serverTrustRoots) ||
    input.serverTrustRoots.length === 0
  ) {
    throw new Error('The private Signal server trust roots are required.');
  }
  output.serverTrustRoots = input.serverTrustRoots.map(value => {
    requireBase64(value, 'serverTrustRoots');
    if (
      Buffer.from(value, 'base64').length !== 33 ||
      signalServiceRoots.has(value)
    ) {
      throw new Error(
        'A private 33-byte Signal server trust root is required; Signal production and staging roots are disabled.'
      );
    }
    return value;
  });
  for (const key of parameterKeys) {
    output[key] = requireBase64(input[key], key);
  }
  return output;
}
