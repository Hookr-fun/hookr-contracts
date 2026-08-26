import assert from "node:assert/strict";
import test from "node:test";
import { once } from "node:events";

import { createRpcRedactor } from "./redact-rpc-stream.mjs";

test("RPC stderr redactor removes exact, encoded, host, path, and cross-chunk endpoint forms", async () => {
  const rpc = "https://secret-subdomain.example.test/v2/super-secret-api-key?token=another-secret-token";
  const redactor = createRpcRedactor({ HOOKR_RPC_URL: rpc, ETH_RPC_URL: rpc });
  let output = "";
  redactor.on("data", (chunk) => { output += chunk; });
  redactor.write("prompt stays visible\ntransport ");
  redactor.write(rpc.slice(0, 17));
  redactor.write(`${rpc.slice(17)}\n${encodeURIComponent(rpc)}\n`);
  redactor.write("host secret-subdomain.example.test and key super-secret-api-key\n");
  redactor.end();
  await once(redactor, "end");

  assert.match(output, /prompt stays visible/);
  assert.ok(!output.includes(rpc));
  assert.ok(!output.includes(encodeURIComponent(rpc)));
  assert.ok(!output.includes("secret-subdomain.example.test"));
  assert.ok(!output.includes("super-secret-api-key"));
  assert.match(output, /\[REDACTED_RPC\]/);
});
