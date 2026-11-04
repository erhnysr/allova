// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IAllowanceFactory {
    function onOwnershipTransferred(address from, address to) external;
}

contract AllowanceAccount is Ownable2Step, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable usdc;
    address public immutable factory;

    uint256 public createdAtBlock;
    bool public frozen;
    address public guardian;

    uint256 private constant MAX_AGENTS = 20;

    struct Agent {
        string label;
        bool active;
        uint64 expiresAt;
        uint128 maxPerPayment;
        uint128 periodLimit;
        uint32 periodSeconds;
        uint128 totalLimit;
        uint128 bucket;
        uint64 lastRefill;
        uint128 totalSpent;
        bool payeeRestricted;
        uint32 minInterval;
        uint64 lastPaidAt;
    }

    /// @notice Full policy for `configureAgent` (v2). `minInterval` is the minimum
    ///         number of seconds between two payments by the same agent (0 = off).
    struct AgentPolicy {
        string label;
        uint128 maxPerPayment;
        uint128 periodLimit;
        uint32 periodSeconds;
        uint128 totalLimit;
        uint64 expiresAt;
        bool payeeRestricted;
        uint32 minInterval;
    }

    struct PayeeRule {
        bool allowed;
        uint128 cap;
        uint128 spent;
        bool blocked;
        bool configured; // v2: set by setPayee; an explicit allowed=false denies in both modes
    }

    struct PaymentIntent {
        address agent;
        address payee;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
        bytes32 ref;
    }

    enum ActivityKind {
        Funded,
        Withdrawn,
        Paid
    }

    struct ActivityEntry {
        ActivityKind kind;
        address agent;
        address counterparty;
        uint128 amount;
        uint64 timestamp;
        uint64 blockNumber;
        bytes32 ref;
    }

    bytes32 public constant PAYMENT_INTENT_TYPEHASH =
        keccak256(
            "PaymentIntent(address agent,address payee,uint256 amount,uint256 nonce,uint256 deadline,bytes32 ref)"
        );

    address[] private _agentList;
    mapping(address => Agent) private _agents;
    mapping(address => bool) private _isAgent;

    /// @dev agent => rule generation => payee => rule. The generation is bumped by
    ///      `removeAgent`, so a removed-then-re-added key starts with no payee rules.
    mapping(address => mapping(uint64 => mapping(address => PayeeRule))) private _payeeRules;
    mapping(address => uint64) private _ruleGeneration;
    mapping(address => mapping(uint256 => bool)) private _nonces;

    /// @notice Signed-intent epoch per agent. A PaymentIntent is only valid when the
    ///         upper 64 bits of its nonce equal the agent's current epoch. The epoch is
    ///         bumped by `revokeAgent`, `removeAgent` and `invalidateIntents`, so intents
    ///         signed before any of those can never be relayed afterwards.
    mapping(address => uint64) public intentEpoch;

    ActivityEntry[64] private _activity;
    uint256 private _activityHead;

    uint256 public paymentCount;
    uint128 public totalPaid;
    uint128 public totalFunded;
    uint128 public totalWithdrawn;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------
    error ZeroAmount();
    error AccountFrozen();
    error UnknownAgent();
    error AgentRevoked();
    error AgentExpired();
    error InvalidPayee();
    error PayeeNotAllowed();
    error OverPerPayment();
    error OverPeriodLimit();
    error OverTotalLimit();
    error OverPayeeCap();
    error InsufficientBalance();
    error TooManyAgents();
    error InvalidAgentAddress();
    error InvalidLabel();
    error InvalidPeriodSeconds();
    error InvalidExpiresAt();
    error InvalidLimits();
    error ZeroAddress();
    error NotAgentOrOwner();
    error NotGuardianOrOwner();
    error CapBelowSpent();
    error TotalLimitBelowSpent();
    error DeadlinePassed();
    error NonceAlreadyUsed();
    error InvalidSignature();
    error RenounceDisabled();
    error StaleIntent();
    error TooSoon();
    error InvalidMinInterval();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------
    event AgentSet(
        address indexed agent,
        string label,
        uint128 maxPerPayment,
        uint128 periodLimit,
        uint32 periodSeconds,
        uint128 totalLimit,
        uint64 expiresAt,
        bool payeeRestricted
    );
    event AgentRevocation(address indexed agent);
    event AgentRemoved(address indexed agent);
    event PayeeSet(address indexed agent, address indexed payee, bool allowed, uint128 cap);
    event PayeeBlocked(address indexed agent, address indexed payee, bool blocked);
    event Frozen(address indexed by);
    event Unfrozen();
    event GuardianSet(address indexed guardian);
    event Funded(address indexed from, uint128 amount);
    event Withdrawn(address indexed to, uint128 amount);
    event Paid(address indexed agent, address indexed payee, uint128 amount, bytes32 ref, address relayer);
    event NonceUsed(address indexed agent, uint256 nonce);
    event IntentsInvalidated(address indexed agent, uint64 newEpoch);
    event MinIntervalSet(address indexed agent, uint32 minInterval);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------
    constructor(address _usdc, address _factory, address _owner, address _guardian)
        Ownable(_owner)
        EIP712("Allowance", "1")
    {
        usdc = _usdc;
        factory = _factory;
        guardian = _guardian;
        createdAtBlock = block.number;
    }

    // -------------------------------------------------------------------------
    // Ownership overrides
    // -------------------------------------------------------------------------

    /// @dev Disabled: renouncing ownership would brick the account.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @dev Notify the factory on every ownership change except the initial one
    ///      in the constructor (oldOwner == address(0)), so its owner index
    ///      stays correct across two-step transfers.
    function _transferOwnership(address newOwner) internal override {
        address oldOwner = owner();
        super._transferOwnership(newOwner);
        // oldOwner is address(0) only during construction — skip that call.
        if (oldOwner != address(0)) {
            IAllowanceFactory(factory).onOwnershipTransferred(oldOwner, newOwner);
        }
    }

    // -------------------------------------------------------------------------
    // Owner functions
    // -------------------------------------------------------------------------

    function fund(uint128 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);
        totalFunded += amount;
        _recordActivity(ActivityKind.Funded, address(0), msg.sender, amount, bytes32(0));
        emit Funded(msg.sender, amount);
    }

    function withdraw(address to, uint128 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (IERC20(usdc).balanceOf(address(this)) < amount) revert InsufficientBalance();

        totalWithdrawn += amount;
        _recordActivity(ActivityKind.Withdrawn, address(0), to, amount, bytes32(0));

        IERC20(usdc).safeTransfer(to, amount);
        emit Withdrawn(to, amount);
    }

    /// @notice v1-compatible policy setter. Keeps any existing `minInterval`.
    function setAgent(
        address agent,
        string calldata label,
        uint128 maxPerPayment,
        uint128 periodLimit,
        uint32 periodSeconds,
        uint128 totalLimit,
        uint64 expiresAt,
        bool payeeRestricted
    ) external onlyOwner {
        _setAgent(agent, label, maxPerPayment, periodLimit, periodSeconds, totalLimit, expiresAt, payeeRestricted);
    }

    /// @notice v2 policy setter: the full policy, including `minInterval`, in one call.
    function configureAgent(address agent, AgentPolicy calldata p) external onlyOwner {
        if (p.minInterval > p.periodSeconds) revert InvalidMinInterval();
        _setAgent(agent, p.label, p.maxPerPayment, p.periodLimit, p.periodSeconds, p.totalLimit, p.expiresAt, p.payeeRestricted);
        _agents[agent].minInterval = p.minInterval;
        emit MinIntervalSet(agent, p.minInterval);
    }

    function _setAgent(
        address agent,
        string calldata label,
        uint128 maxPerPayment,
        uint128 periodLimit,
        uint32 periodSeconds,
        uint128 totalLimit,
        uint64 expiresAt,
        bool payeeRestricted
    ) internal {
        if (agent == address(0) || agent == owner() || agent == address(this)) revert InvalidAgentAddress();
        if (bytes(label).length > 32) revert InvalidLabel();
        if (maxPerPayment == 0 || maxPerPayment > periodLimit || periodLimit > totalLimit) revert InvalidLimits();
        if (periodSeconds < 60 || periodSeconds > 30 days) revert InvalidPeriodSeconds();
        if (block.timestamp >= expiresAt || expiresAt > block.timestamp + 365 days) revert InvalidExpiresAt();

        Agent storage a = _agents[agent];

        if (_isAgent[agent] && totalLimit < a.totalSpent) revert TotalLimitBelowSpent();

        if (!_isAgent[agent]) {
            if (_agentList.length >= MAX_AGENTS) revert TooManyAgents();
            _isAgent[agent] = true;
            _agentList.push(agent);
            a.bucket = periodLimit;
            a.lastRefill = uint64(block.timestamp);
        } else {
            uint128 availableOld = _available(a);
            a.bucket = uint128(Math.min(uint256(availableOld), uint256(periodLimit)));
            a.lastRefill = uint64(block.timestamp);
        }

        a.label = label;
        a.active = true;
        a.expiresAt = expiresAt;
        a.maxPerPayment = maxPerPayment;
        a.periodLimit = periodLimit;
        a.periodSeconds = periodSeconds;
        a.totalLimit = totalLimit;
        a.payeeRestricted = payeeRestricted;

        emit AgentSet(agent, label, maxPerPayment, periodLimit, periodSeconds, totalLimit, expiresAt, payeeRestricted);
    }

    /// @notice Pause an agent. Also invalidates every intent it signed before now.
    function revokeAgent(address agent) external onlyOwner {
        _agents[agent].active = false;
        _bumpEpoch(agent);
        emit AgentRevocation(agent);
    }

    /// @notice Invalidate every not-yet-relayed intent signed by `agent`.
    ///         Callable by the owner or by the agent key itself.
    function invalidateIntents(address agent) external {
        if (msg.sender != agent && msg.sender != owner()) revert NotAgentOrOwner();
        _bumpEpoch(agent);
    }

    /// @notice Remove an agent entirely (swap-and-pop). Used nonces are kept; payee
    ///         rules are cleared (new rule generation) and pending intents invalidated.
    function removeAgent(address agent) external onlyOwner {
        if (!_isAgent[agent]) revert UnknownAgent();

        // Swap-and-pop from _agentList
        uint256 len = _agentList.length;
        for (uint256 i = 0; i < len; i++) {
            if (_agentList[i] == agent) {
                _agentList[i] = _agentList[len - 1];
                _agentList.pop();
                break;
            }
        }

        _isAgent[agent] = false;
        delete _agents[agent];
        _ruleGeneration[agent] += 1;
        _bumpEpoch(agent);

        emit AgentRemoved(agent);
    }

    function setPayee(address agent, address payee, bool allowed, uint128 cap) external onlyOwner {
        if (payee == address(0)) revert ZeroAddress();
        if (payee == address(this)) revert InvalidPayee();

        PayeeRule storage rule = _rule(agent, payee);
        if (cap > 0 && cap < rule.spent) revert CapBelowSpent();

        // `blocked` is deliberately untouched: only setPayeeBlocked clears a block.
        rule.allowed = allowed;
        rule.cap = cap;
        rule.configured = true;

        emit PayeeSet(agent, payee, allowed, cap);
    }

    /// @notice Block or unblock a payee regardless of payeeRestricted mode.
    function setPayeeBlocked(address agent, address payee, bool blocked) external onlyOwner {
        if (payee == address(0)) revert ZeroAddress();
        if (payee == address(this)) revert InvalidPayee();

        _rule(agent, payee).blocked = blocked;
        emit PayeeBlocked(agent, payee, blocked);
    }

    function setGuardian(address _guardian) external onlyOwner {
        guardian = _guardian;
        emit GuardianSet(_guardian);
    }

    function unfreeze() external onlyOwner {
        frozen = false;
        emit Unfrozen();
    }

    function freeze() external {
        if (msg.sender != owner() && msg.sender != guardian) revert NotGuardianOrOwner();
        frozen = true;
        emit Frozen(msg.sender);
    }

    // -------------------------------------------------------------------------
    // Payments
    // -------------------------------------------------------------------------

    function pay(address payee, uint128 amount, bytes32 ref) external nonReentrant {
        _spend(msg.sender, payee, amount, ref, address(0));
    }

    function payWithSig(PaymentIntent calldata intent, bytes calldata signature) external nonReentrant {
        if (block.timestamp > intent.deadline) revert DeadlinePassed();
        if (uint64(intent.nonce >> 192) != intentEpoch[intent.agent]) revert StaleIntent();
        if (_nonces[intent.agent][intent.nonce]) revert NonceAlreadyUsed();
        if (intent.amount > type(uint128).max) revert OverPerPayment();

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    PAYMENT_INTENT_TYPEHASH,
                    intent.agent,
                    intent.payee,
                    intent.amount,
                    intent.nonce,
                    intent.deadline,
                    intent.ref
                )
            )
        );

        if (!SignatureChecker.isValidSignatureNow(intent.agent, digest, signature)) revert InvalidSignature();

        _nonces[intent.agent][intent.nonce] = true;
        emit NonceUsed(intent.agent, intent.nonce);

        _spend(intent.agent, intent.payee, uint128(intent.amount), intent.ref, msg.sender);
    }

    function cancelNonce(address agent, uint256 nonce) external {
        if (msg.sender != agent && msg.sender != owner()) revert NotAgentOrOwner();
        _nonces[agent][nonce] = true;
        emit NonceUsed(agent, nonce);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function check(address agent, address payee, uint128 amount) external view returns (uint8 reason) {
        if (amount == 0) return 1;
        if (frozen) return 2;
        if (!_isAgent[agent]) return 3;

        Agent storage a = _agents[agent];

        if (!a.active) return 4;
        if (block.timestamp >= a.expiresAt) return 5;
        if (payee == address(0) || payee == address(this)) return 6;

        // Check 7: payee blocked (either mode) OR payeeRestricted and not allowed
        PayeeRule storage rule = _rule(agent, payee);
        if (_payeeDenied(a, rule)) return 7;

        if (amount > a.maxPerPayment) return 8;

        uint128 available = _available(a);
        if (amount > available) return 9;
        if (uint256(a.totalSpent) + amount > a.totalLimit) return 10;

        if (rule.cap > 0 && uint256(rule.spent) + amount > rule.cap) return 11;
        if (IERC20(usdc).balanceOf(address(this)) < amount) return 12;
        if (_tooSoon(a)) return 13;

        return 0;
    }

    function availableNow(
        address agent
    ) external view returns (uint128 periodAvailable, uint128 totalRemaining, uint64 expiresAt, bool active) {
        Agent storage a = _agents[agent];

        periodAvailable = _available(a);
        if (a.totalSpent > a.totalLimit) {
            totalRemaining = 0;
        } else {
            totalRemaining = a.totalLimit - a.totalSpent;
        }
        expiresAt = a.expiresAt;
        active = a.active;
    }

    function getAgents() external view returns (address[] memory) {
        return _agentList;
    }

    function getAgent(address agent) external view returns (Agent memory) {
        return _agents[agent];
    }

    function getPayee(address agent, address payee) external view returns (PayeeRule memory) {
        return _rule(agent, payee);
    }

    /// @notice Build a nonce valid for `agent`'s current epoch: (epoch << 192) | seq.
    function nonceFor(address agent, uint192 seq) external view returns (uint256) {
        return (uint256(intentEpoch[agent]) << 192) | uint256(seq);
    }

    /// @notice Contract version, for tooling.
    function version() external pure returns (string memory) {
        return "2.0.0";
    }

    function recentActivity() external view returns (ActivityEntry[] memory entries) {
        uint256 count = _activityHead < 64 ? _activityHead : 64;
        entries = new ActivityEntry[](count);

        for (uint256 i = 0; i < count; i++) {
            uint256 idx = (_activityHead - 1 - i) % 64;
            entries[i] = _activity[idx];
        }
    }

    function hashPaymentIntent(PaymentIntent calldata intent) external view returns (bytes32) {
        return
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        PAYMENT_INTENT_TYPEHASH,
                        intent.agent,
                        intent.payee,
                        intent.amount,
                        intent.nonce,
                        intent.deadline,
                        intent.ref
                    )
                )
            );
    }

    function balance() external view returns (uint256) {
        return IERC20(usdc).balanceOf(address(this));
    }

    function nonceUsed(address agent, uint256 nonce) external view returns (bool) {
        return _nonces[agent][nonce];
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _spend(address agent, address payee, uint128 amount, bytes32 ref, address relayer) internal {
        if (amount == 0) revert ZeroAmount();
        if (frozen) revert AccountFrozen();
        if (!_isAgent[agent]) revert UnknownAgent();

        Agent storage a = _agents[agent];

        if (!a.active) revert AgentRevoked();
        if (block.timestamp >= a.expiresAt) revert AgentExpired();
        if (payee == address(0) || payee == address(this)) revert InvalidPayee();

        PayeeRule storage rule = _rule(agent, payee);

        // Check 7: blocked (both modes) takes priority, then payeeRestricted+not allowed
        if (_payeeDenied(a, rule)) revert PayeeNotAllowed();

        if (amount > a.maxPerPayment) revert OverPerPayment();

        uint128 available = _available(a);
        if (amount > available) revert OverPeriodLimit();
        if (uint256(a.totalSpent) + amount > a.totalLimit) revert OverTotalLimit();
        if (rule.cap > 0 && uint256(rule.spent) + amount > rule.cap) revert OverPayeeCap();
        if (IERC20(usdc).balanceOf(address(this)) < amount) revert InsufficientBalance();
        if (_tooSoon(a)) revert TooSoon();

        a.bucket = available - amount;
        a.lastRefill = uint64(block.timestamp);
        a.lastPaidAt = uint64(block.timestamp);
        a.totalSpent += amount;

        rule.spent += amount;

        paymentCount += 1;
        totalPaid += amount;

        _recordActivity(ActivityKind.Paid, agent, payee, amount, ref);

        IERC20(usdc).safeTransfer(payee, amount);
        emit Paid(agent, payee, amount, ref, relayer);
    }

    function _recordActivity(
        ActivityKind kind,
        address agent,
        address counterparty,
        uint128 amount,
        bytes32 ref
    ) internal {
        _activity[_activityHead % 64] = ActivityEntry({
            kind: kind,
            agent: agent,
            counterparty: counterparty,
            amount: amount,
            timestamp: uint64(block.timestamp),
            blockNumber: uint64(block.number),
            ref: ref
        });
        _activityHead += 1;
    }

    function _rule(address agent, address payee) internal view returns (PayeeRule storage) {
        return _payeeRules[agent][_ruleGeneration[agent]][payee];
    }

    /// @dev Denied if blocked (any mode), explicitly set to not-allowed (any mode, v2),
    ///      or not allowlisted while the agent is payee-restricted.
    function _payeeDenied(Agent storage a, PayeeRule storage rule) internal view returns (bool) {
        if (rule.blocked) return true;
        if (rule.configured && !rule.allowed) return true;
        return a.payeeRestricted && !rule.allowed;
    }

    function _bumpEpoch(address agent) internal {
        uint64 next = intentEpoch[agent] + 1;
        intentEpoch[agent] = next;
        emit IntentsInvalidated(agent, next);
    }

    function _tooSoon(Agent storage a) internal view returns (bool) {
        return a.minInterval != 0 && a.lastPaidAt != 0 && block.timestamp < uint256(a.lastPaidAt) + a.minInterval;
    }

    function _available(Agent storage a) internal view returns (uint128) {
        if (a.periodLimit == 0 || a.periodSeconds == 0) {
            return 0;
        }

        uint256 elapsed = block.timestamp - a.lastRefill;
        uint256 refill = Math.mulDiv(elapsed, a.periodLimit, a.periodSeconds);
        uint256 available = Math.min(uint256(a.periodLimit), uint256(a.bucket) + refill);
        return uint128(available);
    }
}
