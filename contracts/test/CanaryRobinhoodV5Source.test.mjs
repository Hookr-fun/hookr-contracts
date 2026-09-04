import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sourceUrl = new URL("../script/CanaryRobinhoodV5.s.sol", import.meta.url);
const source = readFileSync(sourceUrl, "utf8");

function bodyOf(name) {
  const declaration = source.indexOf(`function ${name}(`);
  assert.notEqual(declaration, -1, `missing ${name}()`);
  const open = source.indexOf("{", declaration);
  assert.notEqual(open, -1, `${name}() has no body`);
  let depth = 0;
  for (let index = open; index < source.length; index += 1) {
    if (source[index] === "{") depth += 1;
    if (source[index] === "}") depth -= 1;
    if (depth === 0) return source.slice(open + 1, index);
  }
  assert.fail(`${name}() body is unterminated`);
}

const compact = (value) => value.replace(/\s+/g, " ").trim();
const occurrences = (value, needle) => value.split(needle).length - 1;
const beforeBroadcast = (body, needle, label) => {
  const check = body.indexOf(needle);
  const broadcast = body.indexOf("vm.startBroadcast(me)");
  assert.notEqual(check, -1, `${label} is missing`);
  assert.notEqual(broadcast, -1, "startBroadcast is missing");
  assert.ok(check < broadcast, `${label} must run before startBroadcast`);
};

test("Phase-A recovery exposes the reviewed 1+2+1+2 Forge split and no bid sender", () => {
  const expected = [
    "openInstant",
    "buyInstantLaunchAuction",
    "launchHookrPair",
    "buyHookrPair",
  ];
  for (const name of expected) {
    assert.match(source, new RegExp(`function\\s+${name}\\(\\)\\s+external`));
  }
  assert.doesNotMatch(source, /function\s+(?:run|finish|settle)\s*\(/);
  assert.doesNotMatch(source, /`(?:run|finish|settle)\(\)`/);
  assert.match(source, /FOUR raw Forge artifacts \(1 \+ 2 \+ 1 \+ 2\)/);
  assert.doesNotMatch(source, /function\s+bidLaunchHookr\s*\(/);
  assert.doesNotMatch(source, /\.submitBid\s*(?:\{|\()/);

  const one = bodyOf("openInstant");
  assert.equal(occurrences(one, "pad.launchInstant{value: fee}"), 1);
  assert.equal(occurrences(one, "vm.startBroadcast(me)"), 1);
  assert.ok(
    !one.includes("router.exactInput") &&
      !one.includes("launchAuction") &&
      !one.includes("submitBid"),
  );

  const twoThree = bodyOf("buyInstantLaunchAuction");
  assert.equal(
    occurrences(twoThree, "router.exactInput{value: CANARY_BUY_WEI}"),
    1,
  );
  assert.equal(occurrences(twoThree, "pad.launchAuction{value: fee}"), 1);
  assert.ok(
    twoThree.indexOf("router.exactInput") <
      twoThree.indexOf("pad.launchAuction"),
  );

  const six = bodyOf("launchHookrPair");
  assert.equal(occurrences(six, "pad.launchInstant{value: fee}"), 1);
  assert.equal(occurrences(six, "vm.startBroadcast(me)"), 1);
  assert.ok(!six.includes("submitBid") && !six.includes("router.exactInput"));

  const sixSeven = bodyOf("buyHookrPair");
  assert.equal(
    occurrences(sixSeven, ".approve(address(router), CANARY_HOOKR_BUY)"),
    1,
  );
  assert.equal(occurrences(sixSeven, "router.exactInput("), 1);
  assert.ok(
    sixSeven.indexOf(".approve") < sixSeven.indexOf("router.exactInput"),
  );
});

test("timing and headroom are pinned at every split boundary", () => {
  assert.match(source, /CANARY_AUCTION_DURATION_BLOCKS\s*=\s*20_000\s*;/);
  assert.match(source, /CANARY_GUARD_BLOCKS\s*=\s*20_000\s*;/);
  assert.match(source, /guardBlocks:\s*CANARY_GUARD_BLOCKS/);
  assert.match(bodyOf("openInstant"), /_requireTiming\(pad,\s*125_000\s*\)/);
  assert.match(
    bodyOf("buyInstantLaunchAuction"),
    /_requireTiming\(pad,\s*CANARY_AUCTION_DURATION_BLOCKS\s*\)/,
  );
  assert.match(
    bodyOf("launchHookrPair"),
    /_requireTiming\(pad,\s*125_000\s*\)/,
  );
  assert.match(bodyOf("buyHookrPair"), /_requireTiming\(pad,\s*125_000\s*\)/);
  assert.doesNotMatch(source, /setAuctionTiming\(2500,\s*0,\s*1\)/);

  assert.doesNotMatch(
    bodyOf("launchHookrPair"),
    /auctionEndBlock[\s\S]*HEADROOM|block\.number/,
  );
});

test("every dynamic CREATE-derived consumer authenticates mined launch state before signing", () => {
  const helper = compact(bodyOf("_authenticatedLaunch"));
  assert.match(
    helper,
    /token\.code\.length > 0 && pad\.launchedByIntent\(me, intent\) == token/,
  );
  assert.match(helper, /launch\.token == token && launch\.creator == me/);
  assert.match(helper, /launch\.mode/);
  assert.match(helper, /launch\.status/);
  assert.match(helper, /launch\.quote/);

  const instantBuy = compact(bodyOf("buyInstantLaunchAuction"));
  assert.match(instantBuy, /"CANARY_INSTANT_TOKEN"/);
  assert.match(instantBuy, /LaunchMode\.Instant/);
  assert.match(instantBuy, /LaunchStatus\.Live/);
  assert.match(instantBuy, /Quote\.Eth/);
  beforeBroadcast(
    bodyOf("buyInstantLaunchAuction"),
    "_authenticatedLaunch(",
    "instant-token authentication",
  );

  const hookrLaunch = compact(bodyOf("launchHookrPair"));
  assert.match(hookrLaunch, /"CANARY_AUCTION_TOKEN"/);
  assert.match(hookrLaunch, /LaunchMode\.Bonded/);
  assert.match(hookrLaunch, /LaunchStatus\.Auctioning/);
  assert.match(hookrLaunch, /LaunchStatus\.Live/);
  assert.match(
    hookrLaunch,
    /address auction = vm\.envAddress\("CANARY_AUCTION"\)/,
  );
  assert.match(
    hookrLaunch,
    /launch\.auction == auction && auction\.code\.length > 0/,
  );
  assert.match(
    hookrLaunch,
    /ICanaryAuction\(auction\)\.endBlock\(\) == launch\.auctionEndBlock/,
  );
  beforeBroadcast(
    bodyOf("launchHookrPair"),
    "pad.getLaunch(auctionToken)",
    "auction-token authentication",
  );
  beforeBroadcast(
    bodyOf("launchHookrPair"),
    "launch.auction == auction",
    "CCA authentication",
  );

  const hookrBuy = compact(bodyOf("buyHookrPair"));
  assert.match(hookrBuy, /"CANARY_HOOKR_PAIR_TOKEN"/);
  assert.match(hookrBuy, /LaunchMode\.Instant/);
  assert.match(hookrBuy, /LaunchStatus\.Live/);
  assert.match(hookrBuy, /Quote\.Hookr/);
  beforeBroadcast(
    bodyOf("buyHookrPair"),
    "_authenticatedLaunch(",
    "HOOKR-pair authentication",
  );
});

test("HOOKR recovery has no lifecycle dependency on the independent auction", () => {
  const launch = compact(bodyOf("launchHookrPair"));
  assert.match(
    launch,
    /status\) == uint8\(HookrLaunchpadV5\.LaunchStatus\.Auctioning\)/,
  );
  assert.match(
    launch,
    /status\) == uint8\(HookrLaunchpadV5\.LaunchStatus\.Live\)/,
  );
  assert.doesNotMatch(launch, /LaunchStatus\.Failed/);
  assert.doesNotMatch(
    launch,
    /CANARY_FINISH_MIN_BLOCK_HEADROOM|block\.number|bids\(/,
  );
});

test("the local ArbSys shim remains outside every broadcast list", () => {
  for (const name of [
    "openInstant",
    "buyInstantLaunchAuction",
    "launchHookrPair",
    "buyHookrPair",
  ]) {
    const body = bodyOf(name);
    beforeBroadcast(
      body,
      "_installArbSysSimulationShim()",
      `${name} ArbSys shim`,
    );
    assert.equal(occurrences(body, "_installArbSysSimulationShim()"), 1);
  }
  assert.doesNotMatch(source, /vm\.startBroadcast[\s\S]{0,300}vm\.etch/);
});
