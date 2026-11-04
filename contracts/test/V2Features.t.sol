// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AllowanceAccount} from "../AllowanceAccount.sol";
import {AllowanceTestBase} from "./TestHelpers.sol";

/// @notice v2 features: configureAgent + minInterval, intent epochs, invalidateIntents.
contract V2FeaturesTest is AllowanceTestBase {
    uint128 constant AMT = 100_000; // 0.1 USDC
    uint32 constant GAP = 600; // 10 minutes

    function setUp() public override {
        super.setUp();
        _fund(50_000_000);
    }

    function _policy(uint32 minInterval) internal view returns (AllowanceAccount.AgentPolicy memory p) {
        p = AllowanceAccount.AgentPolicy({
            label: "research-bot",
            maxPerPayment: MAX_PER,
            periodLimit: PERIOD,
            periodSeconds: PSEC,
            totalLimit: TOTAL,
            expiresAt: uint64(block.timestamp + EXPIRES_IN),
            payeeRestricted: false,
            minInterval: minInterval
        });
    }

    function _configure(uint32 minInterval) internal {
        vm.prank(owner);
        account.configureAgent(agent1, _policy(minInterval));
    }

    // -----------------------------------------------------------------------
    // configureAgent / minInterval
    // -----------------------------------------------------------------------

    function test_configureAgent_setsFullPolicy() public {
        vm.expectEmit(true, false, false, true, address(account));
        emit AllowanceAccount.MinIntervalSet(agent1, GAP);
        _configure(GAP);

        AllowanceAccount.Agent memory a = account.getAgent(agent1);
        assertEq(a.label, "research-bot");
        assertEq(a.maxPerPayment, MAX_PER);
        assertEq(a.minInterval, GAP);
        assertTrue(a.active);
        assertEq(account.getAgents().length, 1);
    }

    function test_configureAgent_onlyOwner() public {
        AllowanceAccount.AgentPolicy memory p = _policy(GAP);
        vm.prank(agent1);
        vm.expectRevert();
        account.configureAgent(agent1, p);
    }

    function test_configureAgent_minIntervalAbovePeriodReverts() public {
        AllowanceAccount.AgentPolicy memory p = _policy(PSEC + 1);
        vm.prank(owner);
        vm.expectRevert(AllowanceAccount.InvalidMinInterval.selector);
        account.configureAgent(agent1, p);
    }

    function test_minInterval_blocksBurstThenAllowsAfterGap() public {
        _configure(GAP);

        vm.prank(agent1);
        account.pay(payee1, AMT, bytes32("1"));

        // Second payment in the same block: blocked.
        assertEq(account.check(agent1, payee1, AMT), 13);
        vm.prank(agent1);
        vm.expectRevert(AllowanceAccount.TooSoon.selector);
        account.pay(payee1, AMT, bytes32("2"));

        // One second before the gap ends: still blocked.
        vm.warp(block.timestamp + GAP - 1);
        vm.prank(agent1);
        vm.expectRevert(AllowanceAccount.TooSoon.selector);
        account.pay(payee1, AMT, bytes32("2"));

        // Exactly at the gap: allowed.
        vm.warp(block.timestamp + 1);
        assertEq(account.check(agent1, payee1, AMT), 0);
        vm.prank(agent1);
        account.pay(payee1, AMT, bytes32("2"));
        assertEq(account.paymentCount(), 2);
    }

    function test_minInterval_zeroMeansOff() public {
        _configure(0);
        vm.startPrank(agent1);
        account.pay(payee1, AMT, bytes32("1"));
        account.pay(payee1, AMT, bytes32("2"));
        vm.stopPrank();
        assertEq(account.paymentCount(), 2);
    }

    function test_minInterval_appliesToPayWithSig() public {
        _configure(GAP);
        (AllowanceAccount.PaymentIntent memory i1, bytes memory s1) = _signIntent(
            agentKey1, agent1, payee1, AMT, account.nonceFor(agent1, 1), block.timestamp + 1 hours, bytes32(0), address(account)
        );
        (AllowanceAccount.PaymentIntent memory i2, bytes memory s2) = _signIntent(
            agentKey1, agent1, payee1, AMT, account.nonceFor(agent1, 2), block.timestamp + 1 hours, bytes32(0), address(account)
        );
        account.payWithSig(i1, s1);
        vm.expectRevert(AllowanceAccount.TooSoon.selector);
        account.payWithSig(i2, s2);
    }

    function test_legacySetAgent_keepsMinInterval() public {
        _configure(GAP);
        _setAgent1(); // v1 setter, e.g. from an older client
        assertEq(account.getAgent(agent1).minInterval, GAP);
    }

    function test_removeAgent_resetsMinInterval() public {
        _configure(GAP);
        vm.prank(owner);
        account.removeAgent(agent1);
        _setAgent1();
        assertEq(account.getAgent(agent1).minInterval, 0);
    }

    // -----------------------------------------------------------------------
    // Intent epochs
    // -----------------------------------------------------------------------

    function test_nonceFor_encodesEpoch() public {
        _setAgent1();
        assertEq(account.nonceFor(agent1, 5), 5);
        vm.prank(owner);
        account.invalidateIntents(agent1);
        assertEq(account.intentEpoch(agent1), 1);
        assertEq(account.nonceFor(agent1, 5), (uint256(1) << 192) | 5);
    }

    function test_invalidateIntents_byAgent() public {
        _setAgent1();
        (AllowanceAccount.PaymentIntent memory intent, bytes memory sig) = _signIntent(
            agentKey1, agent1, payee1, AMT, 1, block.timestamp + 1 hours, bytes32(0), address(account)
        );

        vm.expectEmit(true, false, false, true, address(account));
        emit AllowanceAccount.IntentsInvalidated(agent1, 1);
        vm.prank(agent1);
        account.invalidateIntents(agent1);

        vm.expectRevert(AllowanceAccount.StaleIntent.selector);
        account.payWithSig(intent, sig);
    }

    function test_invalidateIntents_strangerReverts() public {
        _setAgent1();
        vm.prank(relayer);
        vm.expectRevert(AllowanceAccount.NotAgentOrOwner.selector);
        account.invalidateIntents(agent1);
    }

    function test_futureEpochIntentRejected() public {
        _setAgent1();
        // Signed for epoch 1 while the agent is still at epoch 0.
        (AllowanceAccount.PaymentIntent memory intent, bytes memory sig) = _signIntent(
            agentKey1, agent1, payee1, AMT, (uint256(1) << 192) | 1, block.timestamp + 1 hours, bytes32(0), address(account)
        );
        vm.expectRevert(AllowanceAccount.StaleIntent.selector);
        account.payWithSig(intent, sig);
    }

    function test_freshEpochIntentPaysAfterReAdd() public {
        _setAgent1();
        vm.prank(owner);
        account.removeAgent(agent1);
        _setAgent1();

        (AllowanceAccount.PaymentIntent memory intent, bytes memory sig) = _signIntent(
            agentKey1, agent1, payee1, AMT, account.nonceFor(agent1, 1), block.timestamp + 1 hours, bytes32(0), address(account)
        );
        account.payWithSig(intent, sig);
        assertEq(usdc.balanceOf(payee1), AMT);
    }

    function test_setPayeeTrue_doesNotClearBlock() public {
        _setAgent1();
        vm.startPrank(owner);
        account.setPayeeBlocked(agent1, payee1, true);
        account.setPayee(agent1, payee1, true, 0);
        vm.stopPrank();
        assertEq(account.check(agent1, payee1, AMT), 7);
    }

    function test_setPayeeTrue_reallowsAfterDeny() public {
        _setAgent1();
        vm.startPrank(owner);
        account.setPayee(agent1, payee1, false, 0);
        account.setPayee(agent1, payee1, true, 0);
        vm.stopPrank();
        assertEq(account.check(agent1, payee1, AMT), 0);
    }

    function test_version() public view {
        assertEq(account.version(), "2.0.0");
    }

    // -----------------------------------------------------------------------
    // Fuzz
    // -----------------------------------------------------------------------

    /// Any nonce whose epoch bits differ from the agent's epoch is rejected.
    function testFuzz_wrongEpochAlwaysStale(uint64 epochBits, uint192 seq, uint8 bumps) public {
        _setAgent1();
        bumps = uint8(bound(bumps, 0, 5));
        for (uint256 i = 0; i < bumps; i++) {
            vm.prank(owner);
            account.invalidateIntents(agent1);
        }
        vm.assume(epochBits != account.intentEpoch(agent1));
        uint256 nonce = (uint256(epochBits) << 192) | uint256(seq);
        (AllowanceAccount.PaymentIntent memory intent, bytes memory sig) = _signIntent(
            agentKey1, agent1, payee1, AMT, nonce, block.timestamp + 1 hours, bytes32(0), address(account)
        );
        vm.expectRevert(AllowanceAccount.StaleIntent.selector);
        account.payWithSig(intent, sig);
    }

    /// check() returns 13 exactly when pay() reverts with TooSoon.
    function testFuzz_checkAgreesWithTooSoon(uint32 gap, uint32 wait) public {
        gap = uint32(bound(gap, 1, PSEC));
        wait = uint32(bound(wait, 0, PSEC));
        _configure(gap);
        vm.prank(agent1);
        account.pay(payee1, 1_000, bytes32(0));

        vm.warp(block.timestamp + wait);
        uint8 code = account.check(agent1, payee1, 1_000);
        vm.prank(agent1);
        if (wait < gap) {
            assertEq(code, 13);
            vm.expectRevert(AllowanceAccount.TooSoon.selector);
            account.pay(payee1, 1_000, bytes32(0));
        } else {
            assertEq(code, 0);
            account.pay(payee1, 1_000, bytes32(0));
        }
    }
}
