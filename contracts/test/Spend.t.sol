// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AllowanceAccount} from "../AllowanceAccount.sol";
import {AllowanceTestBase} from "./TestHelpers.sol";

contract SpendTest is AllowanceTestBase {

    function setUp() public override {
        super.setUp();
        // Fund the account
        _fund(50_000_000); // 50 USDC
        // Register agent1 with default policy (no payee restriction)
        _setAgent1();
    }

    // -----------------------------------------------------------------------
    // _spend error paths via pay()
    // -----------------------------------------------------------------------

    function test_pay_zeroAmount() public {
        vm.prank(agent1);
        vm.expectRevert(AllowanceAccount.ZeroAmount.selector);
        account.pay(payee1, 0, bytes32(0));
    }

    function test_pay_frozen_accountFrozen() public {
        vm.prank(owner);
        account.freeze();

        vm.prank(agent1);
        vm.expectRevert(AllowanceAccount.AccountFrozen.selector);
        account.pay(payee1, 100_000, bytes32(0));
    }

    function test_pay_unknownAgent() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(AllowanceAccount.UnknownAgent.selector);
        account.pay(payee1, 100_000, bytes32(0));
    }

    function test_pay_agentRevoked() public {
        vm.prank(owner);
        account.revokeAgent(agent1);

        vm.prank(agent1);
        vm.expectRevert(AllowanceAccount.AgentRevoked.selector);
        account.pay(payee1, 100_000, bytes32(0));
    }

    function test_pay_agentExpired() public {
        // Warp past expiry
        vm.warp(block.timestamp + EXPIRES_IN + 1);

        vm.prank(agent1);
        vm.expectRevert(AllowanceAccount.AgentExpired.selector);
        account.pay(payee1, 100_000, bytes32(0));
    }

    function test_pay_invalidPayee_zero() public {
        vm.prank(agent1);
        vm.expectRevert(AllowanceAccount.InvalidPayee.selector);
        account.pay(address(0), 100_000, bytes32(0));
    }

    function test_pay_invalidPayee_self() public {
        vm.prank(agent1);
        vm.expectRevert(AllowanceAccount.InvalidPayee.selector);
        account.pay(address(account), 100_000, bytes32(0));
    }

    function test_pay_payeeNotAllowed() public {
        // Set up agent with payee restriction
        vm.prank(owner);
        account.setAgent(
            agent2, "agent-two", MAX_PER, PERIOD, PSEC, TOTAL,
            uint64(block.timestamp + EXPIRES_IN), true // payeeRestricted
        );
        // payee1 is not in the allowed list

        vm.prank(agent2);
        vm.expectRevert(AllowanceAccount.PayeeNotAllowed.selector);
        account.pay(payee1, 100_000, bytes32(0));
    }

    function test_pay_payeeAllowed_whenRestricted() public {
        vm.prank(owner);
        account.setAgent(
            agent2, "agent-two", MAX_PER, PERIOD, PSEC, TOTAL,
            uint64(block.timestamp + EXPIRES_IN), true
        );
        // Allow payee1
        vm.prank(owner);
        account.setPayee(agent2, payee1, true, 0);

        vm.prank(agent2);
        account.pay(payee1, 100_000, bytes32(0));
        assertEq(account.getAgent(agent2).totalSpent, 100_000);
    }

    function test_pay_overPerPayment() public {
        vm.prank(agent1);
        vm.expectRevert(AllowanceAccount.OverPerPayment.selector);
        account.pay(payee1, MAX_PER + 1, bytes32(0));
    }

    function test_pay_overPeriodLimit() public {
        // Spend the full bucket
        vm.prank(agent1);
        account.pay(payee1, MAX_PER, bytes32(0)); // 500_000

        // Another 500_000 — only 500_000 left in bucket
        vm.prank(agent1);
        account.pay(payee1, MAX_PER, bytes32(0)); // 500_000 — bucket now 0

        // Next spend should fail
        vm.prank(agent1);
        vm.expectRevert(AllowanceAccount.OverPeriodLimit.selector);
        account.pay(payee1, 1, bytes32(0));
    }

    function test_pay_overTotalLimit() public {
        // Set agent with totalLimit == periodLimit == maxPerPayment = 500_000
        vm.prank(owner);
        account.setAgent(
            agent2, "agent-two", 500_000, 500_000, PSEC, 500_000,
            uint64(block.timestamp + EXPIRES_IN), false
        );

        // Spend 500_000 (the totalLimit)
        vm.prank(agent2);
        account.pay(payee1, 500_000, bytes32(0));

        // Warp to refill bucket
        vm.warp(block.timestamp + PSEC);

        // Try to spend 1 more — bucket refilled but totalLimit exhausted
        vm.prank(agent2);
        vm.expectRevert(AllowanceAccount.OverTotalLimit.selector);
        account.pay(payee1, 1, bytes32(0));
    }

    function test_pay_overPayeeCap() public {
        vm.prank(owner);
        account.setPayee(agent1, payee1, true, 300_000); // cap = 0.3 USDC

        vm.prank(agent1);
        account.pay(payee1, 300_000, bytes32(0)); // reach the cap

        // Warp to refill bucket
        vm.warp(block.timestamp + PSEC);

        vm.prank(agent1);
        vm.expectRevert(AllowanceAccount.OverPayeeCap.selector);
        account.pay(payee1, 1, bytes32(0));
    }

    function test_pay_insufficientBalance() public {
        // Withdraw all USDC first
        vm.prank(owner);
        account.withdraw(owner, 50_000_000);

        vm.prank(agent1);
        vm.expectRevert(AllowanceAccount.InsufficientBalance.selector);
        account.pay(payee1, 100_000, bytes32(0));
    }

    function test_pay_success_emitsPaid() public {
        vm.prank(agent1);
        vm.expectEmit(true, true, false, true, address(account));
        emit AllowanceAccount.Paid(agent1, payee1, 100_000, bytes32("ref1"), address(0));
        account.pay(payee1, 100_000, "ref1");
    }

    function test_pay_success_counters() public {
        uint256 payeeBefore = usdc.balanceOf(payee1);

        vm.prank(agent1);
        account.pay(payee1, 100_000, bytes32(0));

        assertEq(account.paymentCount(), 1);
        assertEq(account.totalPaid(), 100_000);
        assertEq(usdc.balanceOf(payee1), payeeBefore + 100_000);
    }

    // -----------------------------------------------------------------------
    // _spend error paths via payWithSig()
    // -----------------------------------------------------------------------

    function test_payWithSig_zeroAmount() public {
        (AllowanceAccount.PaymentIntent memory intent, bytes memory sig) = _signIntent(
            agentKey1, agent1, payee1, 0, 1, block.timestamp + 1 hours, bytes32(0), address(account)
        );
        vm.expectRevert(AllowanceAccount.ZeroAmount.selector);
        account.payWithSig(intent, sig);
    }

    function test_payWithSig_frozen() public {
        vm.prank(owner);
        account.freeze();

        (AllowanceAccount.PaymentIntent memory intent, bytes memory sig) = _signIntent(
            agentKey1, agent1, payee1, 100_000, 1, block.timestamp + 1 hours, bytes32(0), address(account)
        );
        vm.expectRevert(AllowanceAccount.AccountFrozen.selector);
        account.payWithSig(intent, sig);
    }

    function test_payWithSig_unknownAgent() public {
        address stranger = makeAddr("stranger");
        uint256 strangerKey = 0xDEAD;
        address strangerAddr = vm.addr(strangerKey);

        (AllowanceAccount.PaymentIntent memory intent, bytes memory sig) = _signIntent(
            strangerKey, strangerAddr, payee1, 100_000, 1, block.timestamp + 1 hours, bytes32(0), address(account)
        );
        vm.expectRevert(AllowanceAccount.UnknownAgent.selector);
        account.payWithSig(intent, sig);
    }

    function test_payWithSig_agentRevoked() public {
        vm.prank(owner);
        account.revokeAgent(agent1);

        // v2: revoking bumps the intent epoch, so an epoch-0 intent is stale.
        (AllowanceAccount.PaymentIntent memory intent, bytes memory sig) = _signIntent(
            agentKey1, agent1, payee1, 100_000, 1, block.timestamp + 1 hours, bytes32(0), address(account)
        );
        vm.expectRevert(AllowanceAccount.StaleIntent.selector);
        account.payWithSig(intent, sig);

        // An intent signed for the current epoch reaches the policy check and is revoked.
        (intent, sig) = _signIntent(
            agentKey1, agent1, payee1, 100_000, account.nonceFor(agent1, 1), block.timestamp + 1 hours, bytes32(0), address(account)
        );
        vm.expectRevert(AllowanceAccount.AgentRevoked.selector);
        account.payWithSig(intent, sig);
    }

    // -----------------------------------------------------------------------
    // Revoke and expiry
    // -----------------------------------------------------------------------

    function test_revokeAgent_blocksPayment() public {
        vm.prank(owner);
        account.revokeAgent(agent1);

        vm.prank(agent1);
        vm.expectRevert(AllowanceAccount.AgentRevoked.selector);
        account.pay(payee1, 100_000, bytes32(0));
    }

    function test_revokeAgent_immediatelyEffective() public {
        // Payment works before
        vm.prank(agent1);
        account.pay(payee1, 100_000, bytes32(0));

        // Revoke
        vm.prank(owner);
        account.revokeAgent(agent1);

        // Payment blocked in same block
        vm.prank(agent1);
        vm.expectRevert(AllowanceAccount.AgentRevoked.selector);
        account.pay(payee1, 100_000, bytes32(0));
    }

    function test_expiry_blocksPayment() public {
        vm.warp(block.timestamp + EXPIRES_IN + 1);
        vm.prank(agent1);
        vm.expectRevert(AllowanceAccount.AgentExpired.selector);
        account.pay(payee1, 100_000, bytes32(0));
    }

    // -----------------------------------------------------------------------
    // Freeze / unfreeze
    // -----------------------------------------------------------------------

    function test_freeze_byOwner() public {
        vm.prank(owner);
        account.freeze();
        assertTrue(account.frozen());
    }

    function test_freeze_byGuardian() public {
        vm.prank(guardian);
        account.freeze();
        assertTrue(account.frozen());
    }

    function test_freeze_byRandom_reverts() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(AllowanceAccount.NotGuardianOrOwner.selector);
        account.freeze();
    }

    function test_unfreeze_byOwner() public {
        vm.prank(owner);
        account.freeze();
        vm.prank(owner);
        account.unfreeze();
        assertFalse(account.frozen());
    }

    function test_unfreeze_byGuardian_reverts() public {
        vm.prank(owner);
        account.freeze();
        // Ownable unauthorized
        vm.prank(guardian);
        vm.expectRevert();
        account.unfreeze();
    }

    function test_frozen_blocksPayments() public {
        vm.prank(owner);
        account.freeze();

        vm.prank(agent1);
        vm.expectRevert(AllowanceAccount.AccountFrozen.selector);
        account.pay(payee1, 100_000, bytes32(0));
    }

    function test_frozen_doesNotBlockWithdraw() public {
        vm.prank(owner);
        account.freeze();

        uint256 before = usdc.balanceOf(owner);
        vm.prank(owner);
        account.withdraw(owner, 1_000_000);
        assertEq(usdc.balanceOf(owner), before + 1_000_000);
    }

    function test_frozen_unfreeze_paymentWorks() public {
        vm.prank(owner);
        account.freeze();
        vm.prank(owner);
        account.unfreeze();

        vm.prank(agent1);
        account.pay(payee1, 100_000, bytes32(0)); // should succeed
    }

    // -----------------------------------------------------------------------
    // setPayee validation
    // -----------------------------------------------------------------------

    function test_setPayee_zeroPayee_reverts() public {
        vm.prank(owner);
        vm.expectRevert(AllowanceAccount.ZeroAddress.selector);
        account.setPayee(agent1, address(0), true, 0);
    }

    function test_setPayee_accountAsPayee_reverts() public {
        vm.prank(owner);
        vm.expectRevert(AllowanceAccount.InvalidPayee.selector);
        account.setPayee(agent1, address(account), true, 0);
    }

    // -----------------------------------------------------------------------
    // withdraw edge cases
    // -----------------------------------------------------------------------

    function test_withdraw_zeroAmount_reverts() public {
        vm.prank(owner);
        vm.expectRevert(AllowanceAccount.ZeroAmount.selector);
        account.withdraw(owner, 0);
    }

    function test_withdraw_exceedsBalance_reverts() public {
        vm.prank(owner);
        vm.expectRevert(AllowanceAccount.InsufficientBalance.selector);
        account.withdraw(owner, 50_000_001);
    }

    function test_withdraw_success() public {
        uint256 before = usdc.balanceOf(payee1);
        vm.prank(owner);
        account.withdraw(payee1, 1_000_000);
        assertEq(usdc.balanceOf(payee1), before + 1_000_000);
        assertEq(account.totalWithdrawn(), 1_000_000);
    }

    // -----------------------------------------------------------------------
    // cancelNonce
    // -----------------------------------------------------------------------

    function test_cancelNonce_byOwner() public {
        vm.prank(owner);
        account.cancelNonce(agent1, 99);
        assertTrue(account.nonceUsed(agent1, 99));
    }

    function test_cancelNonce_byAgent() public {
        vm.prank(agent1);
        account.cancelNonce(agent1, 77);
        assertTrue(account.nonceUsed(agent1, 77));
    }

    function test_cancelNonce_notAgentOrOwner_reverts() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(AllowanceAccount.NotAgentOrOwner.selector);
        account.cancelNonce(agent1, 1);
    }

    // -----------------------------------------------------------------------
    // setPayeeBlocked — fix #1: blocked payee in open mode (fix #1)
    // -----------------------------------------------------------------------

    function test_blockedPayee_openMode_reverts() public {
        // agent1 is open mode (payeeRestricted=false)
        vm.prank(owner);
        account.setPayeeBlocked(agent1, payee1, true);

        vm.prank(agent1);
        vm.expectRevert(AllowanceAccount.PayeeNotAllowed.selector);
        account.pay(payee1, 100_000, bytes32(0));
    }

    function test_blockedPayee_restrictedMode_reverts() public {
        // Set up restricted-mode agent with payee1 allowed
        vm.prank(owner);
        account.setAgent(
            agent2, "a2", MAX_PER, PERIOD, PSEC, TOTAL,
            uint64(block.timestamp + EXPIRES_IN), true
        );
        vm.prank(owner);
        account.setPayee(agent2, payee1, true, 0);

        // Block payee1 explicitly
        vm.prank(owner);
        account.setPayeeBlocked(agent2, payee1, true);

        vm.prank(agent2);
        vm.expectRevert(AllowanceAccount.PayeeNotAllowed.selector);
        account.pay(payee1, 100_000, bytes32(0));
    }

    function test_blockedPayee_unblock_allows() public {
        vm.prank(owner);
        account.setPayeeBlocked(agent1, payee1, true);

        // Blocked — payment reverts
        vm.prank(agent1);
        vm.expectRevert(AllowanceAccount.PayeeNotAllowed.selector);
        account.pay(payee1, 100_000, bytes32(0));

        // Unblock
        vm.prank(owner);
        account.setPayeeBlocked(agent1, payee1, false);

        // Payment succeeds
        vm.prank(agent1);
        account.pay(payee1, 100_000, bytes32(0));
    }

    function test_blockedPayee_check_returns7() public {
        vm.prank(owner);
        account.setPayeeBlocked(agent1, payee1, true);

        uint8 reason = account.check(agent1, payee1, 100_000);
        assertEq(reason, 7);
    }

    function test_blockedPayee_emitsPayeeBlocked() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true, address(account));
        emit AllowanceAccount.PayeeBlocked(agent1, payee1, true);
        account.setPayeeBlocked(agent1, payee1, true);
    }

    function test_setPayeeBlocked_zeroPayee_reverts() public {
        vm.prank(owner);
        vm.expectRevert(AllowanceAccount.ZeroAddress.selector);
        account.setPayeeBlocked(agent1, address(0), true);
    }

    function test_setPayeeBlocked_accountAsPayee_reverts() public {
        vm.prank(owner);
        vm.expectRevert(AllowanceAccount.InvalidPayee.selector);
        account.setPayeeBlocked(agent1, address(account), true);
    }

    function test_setPayee_preservesBlocked() public {
        // Block payee1 first
        vm.prank(owner);
        account.setPayeeBlocked(agent1, payee1, true);

        // setPayee (not setPayeeBlocked) should preserve blocked state
        vm.prank(owner);
        account.setPayee(agent1, payee1, true, 0);

        AllowanceAccount.PayeeRule memory rule = account.getPayee(agent1, payee1);
        assertTrue(rule.blocked, "blocked flag should survive setPayee");

        // Still blocked
        vm.prank(agent1);
        vm.expectRevert(AllowanceAccount.PayeeNotAllowed.selector);
        account.pay(payee1, 100_000, bytes32(0));
    }
}
