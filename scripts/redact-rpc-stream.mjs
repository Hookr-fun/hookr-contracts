#!/usr/bin/env node

import { Transform } from "node:stream";
import { pathToFileURL } from "node:url";

const REDACTION = "[REDACTED_RPC]";

const rpcSecrets = (env = process.env) => {
  const patterns = new Set();
  for (const raw of [env.HOOKR_RPC_URL, env.ETH_RPC_URL]) {
    if (typeof raw !== "string" || raw.length === 0) continue;
    for (const candidate of [raw, encodeURI(raw), encodeURIComponent(raw), JSON.stringify(raw).slice(1, -1)]) {
      if (candidate.length >= 8) patterns.add(candidate);
    }
    try {
      const url = new URL(raw);
      for (const candidate of [url.hostname, url.username, url.password, ...url.pathname.split("/"),
        ...url.searchParams.values()]) {
        if (candidate.length >= 8) patterns.add(candidate);
      }
    } catch {
      // URL validity is checked by the caller. Exact-string redaction still applies here.
    }
  }
  return [...patterns].sort((a, b) => b.length - a.length);
};

export function createRpcRedactor(env = process.env) {
  const secrets = rpcSecrets(env);
  let pending = "";
  const drain = (stream, flush = false) => {
    while (pending.length > 0) {
      const exact = secrets.find((secret) => secret === pending);
      const prefix = secrets.some((secret) => secret.startsWith(pending));
      if (exact) {
        stream.push(REDACTION);
        pending = "";
      } else if (!flush && prefix) {
        break;
      } else {
        stream.push(pending[0]);
        pending = pending.slice(1);
      }
    }
  };
  return new Transform({
    decodeStrings: false,
    transform(chunk, _encoding, callback) {
      const text = String(chunk);
      for (const character of text) {
        pending += character;
        drain(this);
      }
      callback();
    },
    flush(callback) {
      drain(this, true);
      callback();
    },
  });
}

const isCli = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isCli) process.stdin.setEncoding("utf8").pipe(createRpcRedactor()).pipe(process.stdout);
