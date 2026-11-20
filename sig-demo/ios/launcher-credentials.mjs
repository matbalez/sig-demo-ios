// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import { constants, openSync, fstatSync, readFileSync, closeSync } from 'node:fs';

/** Reads only the explicitly selected desktop search credential, without logging it. */
export function readBraveCredential(path, { required = false } = {}) {
  let descriptor;
  try {
    descriptor = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    const metadata = fstatSync(descriptor);
    if (!metadata.isFile() || metadata.size < 1 || metadata.size > 65_536)
      throw new Error();
    const bytes = readFileSync(descriptor);
    if (bytes.length !== metadata.size) throw new Error();
    const matches = Array.from(
      bytes.toString('utf8').matchAll(
        /^[\t ]*(?:export[\t ]+)?BRAVE_SEARCH_API_KEY[\t ]*=[\t ]*([^\r\n]*)/gm
      )
    );
    if (matches.length !== 1) throw new Error();
    const key = matches[0][1].trim().replace(/^(['"])(.*)\1$/, '$2');
    if (!/^[\u0021-\u007e]{1,1024}$/.test(key)) throw new Error();
    return key;
  } catch (error) {
    if (!required && error.code === 'ENOENT') return undefined;
    throw new Error('The selected desktop Brave search credential is unavailable or invalid.');
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}
