import { parseAbi } from "viem";

/**
 * The SDK intentionally exports the reviewed integration surface, not every owner or recovery
 * selector in the production contracts. This keeps partner code on the user-facing boundary.
 */
export const hookrLaunchpadV5Abi = parseAbi([
  "struct HookParams { uint32 guardBlocks; uint16 maxBuyBps; uint24 snipeTaxPips; uint24 baseFeePips; uint24 maxFeePips; uint16 surgeSens; uint16 burnBps; uint96 burnTriggerWei; uint16 lpBps; uint16 potBps; uint32 potEveryNBuys; uint96 potMinBuyWei; }",
  "struct FeeRecipient { address to; uint16 bps; }",
  "struct LaunchArgs { string name; string symbol; string tagline; string logoURI; address expectedCreator; uint32 blueprintId; HookParams custom; uint16 creatorFeeBps; FeeRecipient[] feeRecipients; }",
  "struct Blueprint { address author; uint16 royaltyBps; uint32 uses; uint40 savedAtBlock; string name; HookParams params; }",
  "struct Launch { address token; address creator; uint40 launchBlock; uint32 blueprintId; uint8 mode; uint8 status; uint96 openPriceWei; uint96 openFdvWei; uint16 reserveBps; address auction; uint40 auctionEndBlock; uint40 migratedAtBlock; uint160 sqrtPriceX96AtOpen; bytes32 poolId; uint8 quote; HookParams hookParams; }",
  "function contractName() pure returns (string)",
  "function contractVersion() pure returns (string)",
  "function creationFeeWei() view returns (uint96)",
  "function blueprintsCount() view returns (uint256)",
  "function getBlueprint(uint32 id) view returns (Blueprint)",
  "function getLaunch(address token) view returns (Launch)",
  "function launchedByIntent(address creator, bytes32 intentId) view returns (address token)",
  "function hook() view returns (address)",
  "function poolManager() view returns (address)",
  "function hookrToken() view returns (address)",
  "function instantOpenFdvWei() view returns (uint96)",
  "function hookrInstantOpenFdv() view returns (uint96)",
  "function auctionDurationBlocks() view returns (uint64)",
  "function claimDelayBlocks() view returns (uint64)",
  "function migrationDelayBlocks() view returns (uint64)",
  "function saveBlueprint(string name, HookParams params, uint16 royaltyBps) returns (uint32 id)",
  "function launchInstant(LaunchArgs args, uint8 quote, bytes32 intentId) payable returns (address token)",
  "function launchAuction(LaunchArgs args, uint8 quote, uint96 floorFdvWei, uint96 raiseFloorWei, uint16 reserveBps, bytes32 intentId) payable returns (address token)",
  "event BlueprintSaved(uint32 indexed id, address indexed author, string name, uint16 royaltyBps)",
  "event TokenLaunched(address indexed token, address indexed creator, uint32 indexed blueprintId, uint8 mode, string name, string symbol, string tagline, string logoURI)",
  "event LaunchIntentConsumed(address indexed creator, bytes32 indexed intentId, address indexed token)",
  "event InstantLaunched(address indexed token, bytes32 indexed poolId, uint96 openPriceWei)",
  "event AuctionStarted(address indexed token, address indexed auction, uint40 endBlock, uint96 floorFdvWei, uint96 raiseFloorWei, uint16 reserveBps)",
]);

export const hookrSwapRouterAbi = parseAbi([
  "struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }",
  "struct ExactInputParams { PoolKey key; bool zeroForOne; uint128 amountIn; uint128 amountOutMinimum; uint160 sqrtPriceLimitX96; address recipient; uint256 deadline; }",
  "struct ExactOutputParams { PoolKey key; bool zeroForOne; uint128 amountOut; uint128 amountInMaximum; uint160 sqrtPriceLimitX96; address recipient; uint256 deadline; }",
  "function contractName() pure returns (string)",
  "function contractVersion() pure returns (string)",
  "function poolManager() view returns (address)",
  "function hook() view returns (address)",
  "function quoteToken() view returns (address)",
  "function exactInput(ExactInputParams p) payable returns (uint256 amountOut)",
  "function exactOutput(ExactOutputParams p) payable returns (uint256 amountIn)",
  "event SwapExecuted(address indexed payer, address indexed recipient, address indexed token, bool zeroForOne, bool exactInput, uint256 amountIn, uint256 amountOut)",
]);

export const hookrHookAbi = parseAbi([
  "function contractName() pure returns (string)",
  "function contractVersion() pure returns (string)",
  "function launchpad() view returns (address)",
  "function poolManager() view returns (address)",
]);

export const erc20ApprovalAbi = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
]);
