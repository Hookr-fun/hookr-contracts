// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Admission metadata exposed by an immutable Hookr kernel-instance factory.
interface IHookrKernelInstanceFactoryV1 {
    function stackRegistry() external view returns (address);
    function templateKernelId() external view returns (bytes32);
    function templateKernel() external view returns (address);
    function kernelFamilyId() external view returns (bytes32);
    function kernelVersion() external view returns (uint32);
    function hookFlags() external view returns (uint160);
    function instanceLayoutId() external view returns (bytes32);
    function isInstance(address instance) external view returns (bool);
    function reservationCallerFor(address instance) external view returns (address);
    function reservationConsumed(address instance) external view returns (bool);
    function consumeReservation(address instance, address caller) external;
}
