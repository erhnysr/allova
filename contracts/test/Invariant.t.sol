// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AllowanceFactory} from "../AllowanceFactory.sol";
import {AllowanceAccount} from "../AllowanceAccount.sol";
import {MockERC20} from "./TestHelpers.sol";

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------
contract AllowanceHandler is Test {
    AllowanceAccount public account;
    MockERC20        public usdc;
    address          public owner;
    address          public guardian;

    uint256[3] public agentKeys;
    address[3] public agents;
    address[3] public payees;

    // -----------------------------------------------------------------------
    // Accounting mirrors
    // -----------------------------------------------------------------------
    uint256 public totalFundedMirror;
    uint256 public totalDirectMirror;
    uint256 public totalWithdrawnMirror;
    uint256 public totalPaidMirror;

    mapping(address => uint256) public agentSpentMirror;
    mapping(address => mapping(address => uint256)) public payeeSpentMirror;

    // Nonce tracking — fix #8: track ALL used nonces per agent
    mapping(address => mapping(uint256 => bool)) public nonceUsedMirror;
    // Store the last successful intent per agent for replay tests
    mapping(address => AllowanceAccount.PaymentIntent) public lastIntent;
    mapping(address => bytes) public lastSig;
    mapping(address => bool) public hasSuccessfulIntent;

    bool public badPaymentHappened;
    bool public replaySucceeded;

    // v2: intents signed in an older epoch must never be relayable
    mapping(address => AllowanceAccount.PaymentIntent) public pendingIntent;
    mapping(address => bytes) public pendingSig;
    mapping(address => uint64) public pendingEpoch;
    mapping(address => bool) public hasPending;
    bool public staleIntentSucceeded;

    // v2: no two successful payments by one agent closer than its minInterval
    mapping(address => uint64) public lastPaidMirror;
    bool public intervalViolated;

    uint256 public successfulPaymentCount;

    mapping(address => uint256) public nextNonce;

    bytes32 constant PAYMENT_INTENT_TYPEHASH =
        keccak256("PaymentIntent(address agent,address payee,uint256 amount,uint256 nonce,uint256 deadline,bytes32 ref)");

    constructor(
        AllowanceAccount _account,
        MockERC20 _usdc,
        address _owner,
        address _guardian,
        uint256[3] memory _agentKeys,
        address[3] memory _agents,
        address[3] memory _payees
    ) {
        account   = _account;
        usdc      = _usdc;
        owner     = _owner;
        guardian  = _guardian;
        agentKeys = _agentKeys;
        agents    = _agents;
        payees    = _payees;

        for (uint256 i = 0; i < 3; i++) {
            nextNonce[agents[i]] = 1;
        }
    }

    // -----------------------------------------------------------------------
    // EIP-712 signing helper
    // -----------------------------------------------------------------------
    function _sign(uint256 privKey, AllowanceAccount.PaymentIntent memory intent)
        internal view returns (bytes memory)
    {
        bytes32 domainSep = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("Allowance"),
            keccak256("1"),
            block.chainid,
            address(account)
        ));
        bytes32 structHash = keccak256(abi.encode(
            PAYMENT_INTENT_TYPEHASH,
            intent.agent, intent.payee, intent.amount, intent.nonce, intent.deadline, intent.ref
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _agentIdx(uint256 seed) internal pure returns (uint256) { return seed % 3; }
    function _payeeIdx(uint256 seed) internal pure returns (uint256) { return seed % 3; }

    // -----------------------------------------------------------------------
    // Actions
    // -----------------------------------------------------------------------

    function fund(uint128 amount) external {
        amount = uint128(bound(amount, 1, 100_000_000));
        usdc.mint(owner, amount);
        vm.prank(owner);
        usdc.approve(address(account), amount);
        vm.prank(owner);
        try account.fund(amount) {
            totalFundedMirror += amount;
        } catch {}
    }

    function directTransfer(uint128 amount) external {
        amount = uint128(bound(amount, 1, 100_000_000));
        usdc.mint(address(account), amount);
        totalDirectMirror += amount;
    }

    function withdraw(uint256 agentSeed, uint128 amount) external {
        amount = uint128(bound(amount, 1, 100_000_000));
        address to = payees[_payeeIdx(agentSeed)];
        vm.prank(owner);
        try account.withdraw(to, amount) {
            totalWithdrawnMirror += amount;
        } catch {}
    }

    function setAgent(uint256 agentSeed, uint128 maxPer, uint128 pLim, uint32 pSec, uint128 totLim, bool restricted) external {
        uint256 idx = _agentIdx(agentSeed);
        maxPer  = uint128(bound(maxPer, 1, 10_000_000));
        pLim    = uint128(bound(pLim,   maxPer, 100_000_000));
        totLim  = uint128(bound(totLim, pLim,   1_000_000_000));
        pSec    = uint32(bound(pSec, 60, uint32(30 days)));
        uint64 expires = uint64(block.timestamp + 30 days);

        vm.prank(owner);
        try account.setAgent(agents[idx], "x", maxPer, pLim, pSec, totLim, expires, restricted) {} catch {}
    }

    /// v2 setter with a min interval between payments.
    function configureAgent(uint256 agentSeed, uint128 maxPer, uint128 pLim, uint32 pSec, uint128 totLim, bool restricted, uint32 gap) external {
        uint256 idx = _agentIdx(agentSeed);
        maxPer  = uint128(bound(maxPer, 1, 10_000_000));
        pLim    = uint128(bound(pLim,   maxPer, 100_000_000));
        totLim  = uint128(bound(totLim, pLim,   1_000_000_000));
        pSec    = uint32(bound(pSec, 60, uint32(30 days)));
        gap     = uint32(bound(gap, 0, pSec));
        AllowanceAccount.AgentPolicy memory p = AllowanceAccount.AgentPolicy({
            label: "x", maxPerPayment: maxPer, periodLimit: pLim, periodSeconds: pSec,
            totalLimit: totLim, expiresAt: uint64(block.timestamp + 30 days),
            payeeRestricted: restricted, minInterval: gap
        });
        vm.prank(owner);
        try account.configureAgent(agents[idx], p) {} catch {}
    }

    function invalidateIntents(uint256 agentSeed, bool byAgent) external {
        address agent = agents[_agentIdx(agentSeed)];
        vm.prank(byAgent ? agent : owner);
        try account.invalidateIntents(agent) {} catch {}
    }

    /// Sign an intent for the current epoch and hold it back (not relayed yet).
    function signPending(uint256 agentSeed, uint256 payeeSeed, uint128 amount) external {
        uint256 idx = _agentIdx(agentSeed);
        address agent = agents[idx];
        amount = uint128(bound(amount, 1, 10_000_000));
        uint256 nonce = account.nonceFor(agent, uint192(nextNonce[agent]++));
        AllowanceAccount.PaymentIntent memory intent = AllowanceAccount.PaymentIntent({
            agent: agent, payee: payees[_payeeIdx(payeeSeed)], amount: amount,
            nonce: nonce, deadline: block.timestamp + 365 days, ref: bytes32("pending")
        });
        pendingIntent[agent] = intent;
        pendingSig[agent] = _sign(agentKeys[idx], intent);
        pendingEpoch[agent] = account.intentEpoch(agent);
        hasPending[agent] = true;
    }

    /// Relay a held-back intent only once its epoch is stale: it must always fail.
    function relayStalePending(uint256 agentSeed) external {
        address agent = agents[_agentIdx(agentSeed)];
        if (!hasPending[agent] || account.intentEpoch(agent) == pendingEpoch[agent]) return;
        try account.payWithSig(pendingIntent[agent], pendingSig[agent]) {
            staleIntentSucceeded = true;
        } catch {}
    }

    function _recordPaid(address agent, uint32 gapBefore) internal {
        uint64 last = lastPaidMirror[agent];
        if (gapBefore != 0 && last != 0 && block.timestamp < uint256(last) + gapBefore) {
            intervalViolated = true;
        }
        lastPaidMirror[agent] = uint64(block.timestamp);
    }

    function revokeAgent(uint256 agentSeed) external {
        vm.prank(owner);
        try account.revokeAgent(agents[_agentIdx(agentSeed)]) {} catch {}
    }

    function removeAgent(uint256 agentSeed) external {
        uint256 idx   = _agentIdx(agentSeed);
        address agent = agents[idx];

        // Snapshot spent before removal so we can reset mirrors
        AllowanceAccount.Agent memory a = account.getAgent(agent);
        uint128 spentSnap = a.totalSpent;

        vm.prank(owner);
        try account.removeAgent(agent) {
            // Reset per-agent mirror (struct cleared)
            // totalPaid and balance are unaffected — removal doesn't move funds
            agentSpentMirror[agent] -= spentSnap;
            // v2: removeAgent starts a new payee-rule generation, so per-payee
            // spent restarts at zero for this agent.
            for (uint256 j = 0; j < 3; j++) {
                payeeSpentMirror[agent][payees[j]] = 0;
            }
            lastPaidMirror[agent] = 0;
        } catch {}
    }

    function freeze() external {
        vm.prank(owner);
        try account.freeze() {} catch {}
    }

    function guardianFreeze() external {
        vm.prank(guardian);
        try account.freeze() {} catch {}
    }

    function unfreeze() external {
        vm.prank(owner);
        try account.unfreeze() {} catch {}
    }

    function setPayee(uint256 agentSeed, uint256 payeeSeed, bool allowed, uint128 cap) external {
        address agent = agents[_agentIdx(agentSeed)];
        address payee = payees[_payeeIdx(payeeSeed)];
        uint128 alreadySpent = account.getPayee(agent, payee).spent;
        uint128 minCap = (cap > 0 && allowed) ? alreadySpent : 0;
        if (cap > 0) cap = uint128(bound(cap, minCap, 100_000_000));
        vm.prank(owner);
        try account.setPayee(agent, payee, allowed, cap) {} catch {}
    }

    function setPayeeBlocked(uint256 agentSeed, uint256 payeeSeed, bool blocked) external {
        address agent = agents[_agentIdx(agentSeed)];
        address payee = payees[_payeeIdx(payeeSeed)];
        vm.prank(owner);
        try account.setPayeeBlocked(agent, payee, blocked) {} catch {}
    }

    function pay(uint256 agentSeed, uint256 payeeSeed, uint128 amount) external {
        amount = uint128(bound(amount, 1, 10_000_000));
        uint256 idx   = _agentIdx(agentSeed);
        address agent = agents[idx];
        address payee = payees[_payeeIdx(payeeSeed)];

        bool wasFrozen  = account.frozen();
        AllowanceAccount.Agent memory agState = account.getAgent(agent);
        bool wasRevoked = !agState.active;
        bool wasExpired = agState.expiresAt != 0 && block.timestamp >= agState.expiresAt;

        uint32 gapBefore = agState.minInterval;
        vm.prank(agent);
        try account.pay(payee, amount, bytes32(0)) {
            if (wasFrozen || wasRevoked || wasExpired) {
                badPaymentHappened = true;
            }
            _recordPaid(agent, gapBefore);
            totalPaidMirror += amount;
            agentSpentMirror[agent] += amount;
            payeeSpentMirror[agent][payee] += amount;
            successfulPaymentCount++;
        } catch {}
    }

    function payWithSig(uint256 agentSeed, uint256 payeeSeed, uint128 amount) external {
        amount = uint128(bound(amount, 1, 10_000_000));
        uint256 idx   = _agentIdx(agentSeed);
        address agent = agents[idx];
        address payee = payees[_payeeIdx(payeeSeed)];
        uint256 nonce = account.nonceFor(agent, uint192(nextNonce[agent]++));

        // Guard: skip if already used (shouldn't happen, but safety)
        if (nonceUsedMirror[agent][nonce]) return;

        bool wasFrozen  = account.frozen();
        AllowanceAccount.Agent memory agState = account.getAgent(agent);
        bool wasRevoked = !agState.active;
        bool wasExpired = agState.expiresAt != 0 && block.timestamp >= agState.expiresAt;

        AllowanceAccount.PaymentIntent memory intent = AllowanceAccount.PaymentIntent({
            agent:    agent,
            payee:    payee,
            amount:   amount,
            nonce:    nonce,
            deadline: block.timestamp + 1 hours,
            ref:      bytes32(0)
        });
        bytes memory sig = _sign(agentKeys[idx], intent);

        try account.payWithSig(intent, sig) {
            if (wasFrozen || wasRevoked || wasExpired) {
                badPaymentHappened = true;
            }
            _recordPaid(agent, agState.minInterval);
            nonceUsedMirror[agent][nonce] = true;
            totalPaidMirror += amount;
            agentSpentMirror[agent] += amount;
            payeeSpentMirror[agent][payee] += amount;
            successfulPaymentCount++;

            // Store this intent for replay testing
            lastIntent[agent] = intent;
            lastSig[agent]    = sig;
            hasSuccessfulIntent[agent] = true;
        } catch {}
    }

    /// Fix #8: replay a previously successful signed intent — must always fail.
    function replayIntent(uint256 agentSeed) external {
        address agent = agents[_agentIdx(agentSeed)];
        if (!hasSuccessfulIntent[agent]) return;

        AllowanceAccount.PaymentIntent memory intent = lastIntent[agent];
        bytes memory sig = lastSig[agent];

        try account.payWithSig(intent, sig) {
            // This must never succeed
            replaySucceeded = true;
        } catch {}
    }

    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 30 days);
        vm.warp(block.timestamp + seconds_);
    }
}

// ---------------------------------------------------------------------------
// Invariant test
// ---------------------------------------------------------------------------
contract InvariantTest is Test {
    AllowanceFactory public factory;
    AllowanceAccount public account;
    MockERC20        public usdc;
    AllowanceHandler public handler;

    address public owner    = makeAddr("inv-owner");
    address public guardian = makeAddr("inv-guardian");

    uint256[3] agentKeys = [uint256(0xA1), uint256(0xA2), uint256(0xA3)];

    function setUp() public {
        usdc    = new MockERC20();
        factory = new AllowanceFactory(address(usdc));

        vm.prank(owner);
        account = AllowanceAccount(factory.createAccount(guardian));

        address[3] memory agents;
        agents[0] = vm.addr(agentKeys[0]);
        agents[1] = vm.addr(agentKeys[1]);
        agents[2] = vm.addr(agentKeys[2]);

        address[3] memory payees;
        payees[0] = makeAddr("inv-payee1");
        payees[1] = makeAddr("inv-payee2");
        payees[2] = makeAddr("inv-payee3");

        handler = new AllowanceHandler(
            account, usdc, owner, guardian, agentKeys, agents, payees
        );

        uint64 exp = uint64(block.timestamp + 365 days);
        vm.prank(owner);
        account.setAgent(agents[0], "a0", 1_000_000, 5_000_000, 86_400, 500_000_000, exp, false);
        vm.prank(owner);
        account.setAgent(agents[1], "a1", 1_000_000, 5_000_000, 86_400, 500_000_000, exp, false);
        vm.prank(owner);
        account.setAgent(agents[2], "a2", 1_000_000, 5_000_000, 86_400, 500_000_000, exp, false);

        usdc.mint(owner, 500_000_000);
        vm.prank(owner);
        usdc.approve(address(account), type(uint256).max);
        vm.prank(owner);
        account.fund(100_000_000);

        targetContract(address(handler));
    }

    // -----------------------------------------------------------------------
    // Invariant 1: balance accounting
    // -----------------------------------------------------------------------
    function invariant_balanceAccounting() public view {
        uint256 expected = 100_000_000
            + handler.totalFundedMirror()
            + handler.totalDirectMirror()
            - handler.totalWithdrawnMirror()
            - handler.totalPaidMirror();

        assertEq(
            usdc.balanceOf(address(account)),
            expected,
            "balance invariant broken"
        );
    }

    // -----------------------------------------------------------------------
    // Invariant 2: spend limits — agent totalSpent <= totalLimit;
    //              per-agent totalSpent == agentSpentMirror;
    //              payee spent <= cap; payee spent == payeeSpentMirror
    // -----------------------------------------------------------------------
    function invariant_spendLimits() public view {
        for (uint256 i = 0; i < 3; i++) {
            address agent = handler.agents(i);
            AllowanceAccount.Agent memory a = account.getAgent(agent);
            assertLe(a.totalSpent, a.totalLimit, "agent exceeded totalLimit");
            assertEq(a.totalSpent, handler.agentSpentMirror(agent), "agent totalSpent != mirror");

            for (uint256 j = 0; j < 3; j++) {
                address payee = handler.payees(j);
                AllowanceAccount.PayeeRule memory rule = account.getPayee(agent, payee);
                if (rule.cap > 0) {
                    assertLe(rule.spent, rule.cap, "payee exceeded cap");
                }
                assertEq(rule.spent, handler.payeeSpentMirror(agent, payee), "payee spent != mirror");
            }
        }
    }

    // -----------------------------------------------------------------------
    // Invariant 3: no payment succeeded while frozen/revoked/expired
    // -----------------------------------------------------------------------
    function invariant_noPaymentInBadState() public view {
        assertFalse(handler.badPaymentHappened(), "payment succeeded in bad state");
    }

    // -----------------------------------------------------------------------
    // Invariant 4 (fix #8): replaying a previously successful intent always
    //              reverts (NonceAlreadyUsed).
    // -----------------------------------------------------------------------
    function invariant_noReplay() public view {
        assertFalse(handler.replaySucceeded(), "signed intent was replayed successfully");
    }

    // -----------------------------------------------------------------------
    // Invariant 5 (fix #8): totalPaid mirror == on-chain totalPaid
    // -----------------------------------------------------------------------
    function invariant_noStaleIntent() public view {
        assertFalse(handler.staleIntentSucceeded(), "intent from an old epoch was relayed");
    }

    function invariant_minInterval() public view {
        assertFalse(handler.intervalViolated(), "two payments closer than minInterval");
    }

    function invariant_totalPaidMirror() public view {
        assertEq(
            account.totalPaid(),
            handler.totalPaidMirror(),
            "on-chain totalPaid != mirror"
        );
    }
}
