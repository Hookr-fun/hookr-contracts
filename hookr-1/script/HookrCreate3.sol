// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

/// @notice zefram's CREATE3Factory, the release train's factory.
interface ICREATE3Factory {
    function deploy(bytes32 salt, bytes memory creationCode) external payable returns (address deployed);

    function getDeployed(address deployer, bytes32 salt) external view returns (address deployed);
}

/// @notice CREATE3 address book through zefram's CREATE3Factory.
/// @dev seed        = keccak256(abi.encode("hookr.create3.salt", releaseId, role))
///      salt        = seed[0:29] || counter (3 bytes)
///      hashedSalt  = keccak256(abi.encodePacked(deployer, salt))   (the factory binds the salt to msg.sender)
///      address     = CREATE(proxy, 1), proxy = CREATE2(FACTORY, hashedSalt, PROXY_INITCODE_HASH)   (solmate CREATE3)
///      The deployer must call the factory directly; any other sender derives a different address.
///      A contract is identified by its address AND its runtime keccak, never by address or creator alone: the
///      leftover proxy of every salt can still CREATE contracts under the same creator. Canary release ids start with
///      CANARY_PREFIX and production ids never do, so a canary deploy can never consume a production salt.
///      Mined root addresses never start with DECLINED_PREFIX, Uniswap's signal that a hook opts out of routing.
library HookrCreate3 {
    address internal constant FACTORY = 0xc7c662Fc760FE1d5cB97fd8A68cb43A046da3F7d;
    bytes32 internal constant FACTORY_RUNTIME_KECCAK =
        0x13f328aa6a23392928a9217ab2d39302542863e38dc76da190854379870a794d;
    bytes32 internal constant PROXY_INITCODE_HASH = 0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;
    uint160 internal constant HOOK_MASK = 0x3fff;
    uint256 internal constant COUNTER_LIMIT = 1 << 24;
    /// @notice First address byte Uniswap reads as a request to leave the hook off the routing allowlist.
    uint8 internal constant DECLINED_PREFIX = 0x91;
    /// @notice Prefix of every canary release id.
    bytes internal constant CANARY_PREFIX = "canary-";

    error CounterOutOfRange(uint256 counter);
    error NoHookSalt(string role, uint160 flags);
    error FactoryMismatch(address factory, bytes32 codehash);
    error WrongNamespace(string releaseId, bool canary);
    error AddressOccupied(address predicted);
    error UnexpectedAddress(address deployed, address predicted);
    error NotQualified(address account, bytes32 codehash, bytes32 expected);

    /// @notice Reverts unless the factory holds exactly the pinned runtime. Every deploy path calls it first.
    function requireFactory() internal view {
        if (FACTORY.code.length == 0 || FACTORY.codehash != FACTORY_RUNTIME_KECCAK) {
            revert FactoryMismatch(FACTORY, FACTORY.codehash);
        }
    }

    /// @notice Whether `releaseId` is in the canary namespace.
    function isCanary(string memory releaseId) internal pure returns (bool) {
        bytes memory id = bytes(releaseId);
        bytes memory prefix = CANARY_PREFIX;
        if (id.length < prefix.length) return false;
        for (uint256 i; i < prefix.length; ++i) {
            if (id[i] != prefix[i]) return false;
        }
        return true;
    }

    /// @notice Reverts unless `releaseId` belongs to the requested namespace: canary mode refuses production seeds,
    ///         production mode refuses canary seeds.
    function requireNamespace(string memory releaseId, bool canary) internal pure {
        if (isCanary(releaseId) != canary) revert WrongNamespace(releaseId, canary);
    }

    /// @notice Whether `account` holds exactly the runtime with keccak `runtimeKeccak`.
    function qualified(address account, bytes32 runtimeKeccak) internal view returns (bool) {
        return account.code.length != 0 && account.codehash == runtimeKeccak;
    }

    /// @notice Reverts unless `account` holds exactly the runtime with keccak `runtimeKeccak`.
    function requireQualified(address account, bytes32 runtimeKeccak) internal view {
        if (!qualified(account, runtimeKeccak)) revert NotQualified(account, account.codehash, runtimeKeccak);
    }

    /// @notice Deploys `initCode` at the role's CREATE3 address and qualifies the result by address and runtime keccak.
    /// @dev Must run in the deployer's own call context (a broadcast), since the factory binds the salt to msg.sender.
    ///      Checks, in order: the factory runtime, the namespace, an empty predicted address, the factory's own
    ///      prediction; then the deployed address and its runtime keccak.
    function deploy(
        address deployer,
        string memory releaseId,
        string memory role,
        uint256 counter,
        bytes memory initCode,
        bytes32 runtimeKeccak,
        bool canary
    ) internal returns (address deployed) {
        requireFactory();
        requireNamespace(releaseId, canary);
        bytes32 raw = salt(releaseId, role, counter);
        address predicted = predict(deployer, releaseId, role, counter);
        if (predicted.code.length != 0) revert AddressOccupied(predicted);
        ICREATE3Factory factory = ICREATE3Factory(FACTORY);
        if (factory.getDeployed(deployer, raw) != predicted) revert UnexpectedAddress(address(0), predicted);
        deployed = factory.deploy(raw, initCode);
        if (deployed != predicted) revert UnexpectedAddress(deployed, predicted);
        requireQualified(deployed, runtimeKeccak);
    }

    function seed(string memory releaseId, string memory role) internal pure returns (bytes32) {
        return keccak256(abi.encode("hookr.create3.salt", releaseId, role));
    }

    function salt(string memory releaseId, string memory role, uint256 counter) internal pure returns (bytes32) {
        if (counter >= COUNTER_LIMIT) revert CounterOutOfRange(counter);
        return _salt(bytes29(seed(releaseId, role)), counter);
    }

    function hashedSalt(address deployer, bytes32 raw) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(deployer, raw));
    }

    function proxyOf(bytes32 hashed) internal pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), FACTORY, hashed, PROXY_INITCODE_HASH)))));
    }

    function addressOf(bytes32 hashed) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", proxyOf(hashed), hex"01")))));
    }

    function predict(address deployer, string memory releaseId, string memory role, uint256 counter)
        internal
        pure
        returns (address)
    {
        return addressOf(hashedSalt(deployer, salt(releaseId, role, counter)));
    }

    /// @notice Smallest counter whose address carries exactly `flags` in the low hook-permission bits and does not
    ///         start with DECLINED_PREFIX.
    function mine(address deployer, string memory releaseId, string memory role, uint160 flags)
        internal
        pure
        returns (uint256 counter, bytes32 raw, address target)
    {
        bytes29 prefix = bytes29(seed(releaseId, role));
        for (; counter < COUNTER_LIMIT; ++counter) {
            raw = _salt(prefix, counter);
            target = addressOf(hashedSalt(deployer, raw));
            if (fits(target, flags)) return (counter, raw, target);
        }
        revert NoHookSalt(role, flags);
    }

    /// @notice Whether `target` carries exactly `flags` in the low hook-permission bits and does not start with
    ///         DECLINED_PREFIX.
    function fits(address target, uint160 flags) internal pure returns (bool) {
        return uint160(target) & HOOK_MASK == flags && uint8(uint160(target) >> 152) != DECLINED_PREFIX;
    }

    function _salt(bytes29 prefix, uint256 counter) private pure returns (bytes32) {
        return bytes32(abi.encodePacked(prefix, uint24(counter)));
    }
}
