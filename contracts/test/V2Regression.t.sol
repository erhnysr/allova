// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AllowanceAccount} from "../AllowanceAccount.sol";
import {AllowanceTestBase} from "./TestHelpers.sol";

/// @notice Regression tests for the three findings reported against v1 (KupiaSec, Oct 2026).
///         Every test here uses only the v1 ABI on purpose, so the same file compiles
///         against v1 and fails there: that is the failing-first proof for each fix.
contract V2RegressionTest is AllowanceTestBase {
    uint128 constant AMT = 100_000; // 0.1 USDC

    function setUp() public override {
        super.setUp();
        _fund(50_000_000); // 50 USDC
        _setAgent1();
    }

    // -----------------------------------------------------------------------
    // Finding 1: an intent signed before removeAgent is relayable after re-adding the key
    // -----------------------------------------------------------------------
    function test_regression_intentDoesNotSurviveRemoveAndReAdd() public {
        (AllowanceAccount.PaymentIntent memory intent, bytes memory sig) = _signIntent(
            agentKey1, agent1, payee1, AMT, 7, block.timestamp + 7 days, bytes32("old"), address(account)
        );

        vm.prank(owner);
        account.removeAgent(agent1);
        _setAgent1(); // same key added back later, e.g. for a new job

        uint256 before = usdc.balanceOf(payee1);
        vm.expectRevert();
        account.payWithSig(intent, sig);
        assertEq(usdc.balanceOf(payee1), before, "old intent must not move funds");
    }

    /// Same for revoke + re-enable: a paused agent's pending intents must not come back.
    function test_regression_intentDoesNotSurviveRevokeAndReEnable() public {
        (AllowanceAccount.PaymentIntent memory intent, bytes memory sig) = _signIntent(
            agentKey1, agent1, payee1, AMT, 8, block.timestamp + 7 days, bytes32("old"), address(account)
        );

        vm.prank(owner);
        account.revokeAgent(agent1);
        _setAgent1(); // re-enable

        vm.expectRevert();
        account.payWithSig(intent, sig);
    }

    // -----------------------------------------------------------------------
    // Finding 2: payee rules survive removeAgent and leak into a re-added key
    // -----------------------------------------------------------------------
    function test_regression_allowlistDoesNotSurviveRemove() public {
        // Agent 1 is payee-restricted and allowed to pay payee1.
        _setAgentFull(agent1, "restricted", MAX_PER, PERIOD, PSEC, TOTAL, uint64(block.timestamp + EXPIRES_IN), true);
        vm.prank(owner);
        account.setPayee(agent1, payee1, true, 0);

        vm.prank(owner);
        account.removeAgent(agent1);

        // Re-added with a fresh, empty allowlist in mind.
        _setAgentFull(agent1, "restricted", MAX_PER, PERIOD, PSEC, TOTAL, uint64(block.timestamp + EXPIRES_IN), true);

        vm.prank(agent1);
        vm.expectRevert();
        account.pay(payee1, AMT, bytes32(0));
        assertEq(account.check(agent1, payee1, uint128(AMT)), 7, "stale allowlist entry must be gone");
    }

    function test_regression_payeeCapSpentDoesNotSurviveRemove() public {
        vm.prank(owner);
        account.setPayee(agent1, payee2, true, uint128(AMT));
        vm.prank(agent1);
        account.pay(payee2, AMT, bytes32(0)); // cap fully used

        vm.prank(owner);
        account.removeAgent(agent1);
        _setAgent1();

        // A fresh agent starts with no per-payee cap at all.
        assertEq(account.getPayee(agent1, payee2).spent, 0);
        assertEq(account.getPayee(agent1, payee2).cap, 0);
    }

    // -----------------------------------------------------------------------
    // Finding 3: setPayee(..., allowed=false) does not stop payments in open mode
    // -----------------------------------------------------------------------
    function test_regression_setPayeeFalseDeniesInOpenMode() public {
        // agent1 is in open mode (payeeRestricted = false).
        vm.prank(owner);
        account.setPayee(agent1, payee3, false, 0);

        vm.prank(agent1);
        vm.expectRevert();
        account.pay(payee3, AMT, bytes32(0));
        assertEq(account.check(agent1, payee3, uint128(AMT)), 7);

        // Payees never touched by setPayee are still payable in open mode.
        vm.prank(agent1);
        account.pay(payee1, AMT, bytes32(0));
    }
}
