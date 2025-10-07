// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SuperchainERC20} from "../tokens/SuperchainERC20.sol";
import {AdapterRegistry} from "../strategy/AdapterRegistry.sol";

/// @dev Minimal interface to query adapter TVL for cap enforcement.
interface IAdapterLike {
    function totalAssets() external view returns (uint256);
}

/// @title SpokeYieldVault
/// @notice ERC4626 vault on spokes; mints/burns LST shares token; integrates adapters.
contract SpokeYieldVault is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC4626Upgradeable
{
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");
    bytes32 public constant HUB_ROLE = keccak256("HUB_ROLE");
    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");

    // Feature flags
    bool public depositsEnabled;
    bool public borrowsEnabled;
    bool public bridgeEnabled;

    // Storage
    address public hub;
    SuperchainERC20 public lst;
    AdapterRegistry public adapterRegistry;

    // Fees / buffers (example: performance fee in bps)
    uint16 public performanceFeeBps; // 0-10000
    address public feeRecipient;
    uint16 public withdrawalBufferBps; // 0-10000 portion of TVL to serve locally

    // Events
    event AdapterAllocated(address indexed adapter, address indexed asset, uint256 assets);
    event AdapterDeallocated(address indexed adapter, address indexed asset, uint256 assets);
    event Harvest(address indexed adapter, address indexed asset, uint256 yieldAmount);
    event LstMinted(address indexed user, uint256 shares, address indexed lst);
    event LstBurned(address indexed user, uint256 shares, address indexed lst);
    event RemoteCreditHandled(
        address indexed user, address indexed asset, uint256 assets, uint256 shares, uint256 nonce, bytes32 actionId
    );
    event RemoteLiquidityServed(address indexed toUser, address indexed asset, uint256 assets, bytes32 actionId);
    event BorrowPayout(address indexed to, address indexed asset, uint256 amount, bytes32 actionId, uint256 ts);
    event SharesSeized(address indexed user, address indexed to, uint256 shares, bytes32 actionId);
    event FlagsUpdated(bool depositsEnabled, bool borrowsEnabled, bool bridgeEnabled);
    event StateChanged(uint8 previous, uint8 current);
    // Withdraw queue events (for harness/integration testing)
    event WithdrawQueued(address indexed user, uint256 indexed claimId, uint256 shares, uint256 ts);
    event WithdrawFulfilled(
        address indexed user, uint256 indexed claimId, uint256 assets, bytes32 actionId, uint256 ts
    );

    // Errors
    error DepositsDisabled();
    error BorrowsDisabled();
    error BridgeDisabled();
    error NotAllowedAdapter();
    error CapExceeded();
    error NonceUsed(bytes32);
    error InsufficientBuffer();
    error DuplicateClaim();
    error InvalidArray();
    error BadState();

    // Nonce replay protection for inbound messages
    mapping(bytes32 => bool) private _usedNonce;

    // --- Lightweight withdraw queue (testing harness support) ---
    struct Claim {
        address user;
        uint128 shares;
        uint128 filledAssets;
        bool active;
        uint64 ts;
    }

    mapping(uint256 => Claim) public claims; // claimId => Claim
    // Unique claim nonces to avoid same-block collisions when hashing IDs
    uint256 private _claimNonce;
    // Per-epoch outflow cap
    uint16 public epochOutflowCapBps; // cap in bps applied to TVL per epoch
    uint64 public epochLengthSec; // epoch duration in seconds
    mapping(uint64 => uint256) public epochOutflow; // epoch => assets outflowed
    // Aggregate mapping: epoch => user => actionId => claimId
    mapping(uint64 => mapping(address => mapping(bytes32 => uint256))) private _epochClaimOf;
    // Fulfillment idempotency using actionIds
    mapping(bytes32 => bool) private _fulfilledAction;

    // ERC4626 virtual shares/assets to protect first depositor and matured yield hijack
    uint256 private constant VIRTUAL_ASSETS = 1e6;
    uint256 private constant VIRTUAL_SHARES = 1e6;

    // --- Rebalance state machine ---
    enum VaultState {
        Idle,
        Allocating,
        Deallocating,
        Harvesting
    }

    VaultState public state;
    uint64 public stateSince; // timestamp when current state was entered
    uint64 public maxStateDuration; // optional cap on time spent out of Idle

    // --- Two-step governor ---
    address public governor;
    address public pendingGovernor;

    function initialize(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address hub_,
        address initialGovernor,
        address rebalancer,
        address adapterRegistry_,
        address feeRecipient_,
        uint16 performanceFeeBps_,
        address lst_
    ) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __ERC20_init(name_, symbol_);
        __ERC4626_init(asset_);
        hub = hub_;
        adapterRegistry = AdapterRegistry(adapterRegistry_);
        feeRecipient = feeRecipient_;
        performanceFeeBps = performanceFeeBps_;
        lst = SuperchainERC20(lst_);
        _grantRole(DEFAULT_ADMIN_ROLE, initialGovernor);
        _grantRole(GOVERNOR_ROLE, initialGovernor);
        _grantRole(REBALANCER_ROLE, rebalancer);
        depositsEnabled = true;
        bridgeEnabled = true;
        _grantRole(HUB_ROLE, hub_);
        state = VaultState.Idle;
        stateSince = uint64(block.timestamp);
        governor = initialGovernor;
    }

    function _authorizeUpgrade(address) internal override onlyRole(GOVERNOR_ROLE) {}

    // --- Flags ---
    function setFlags(bool _deposits, bool _borrows, bool _bridge) external onlyRole(GOVERNOR_ROLE) {
        depositsEnabled = _deposits;
        borrowsEnabled = _borrows;
        bridgeEnabled = _bridge;
        emit FlagsUpdated(_deposits, _borrows, _bridge);
    }

    // --- State machine configs ---
    function setMaxStateDuration(uint64 seconds_) external onlyRole(GOVERNOR_ROLE) {
        maxStateDuration = seconds_;
    }

    /// @notice Emergency reset to Idle if a prior transition appears stuck (off-chain or adapter issue).
    function forceIdle() external onlyRole(GOVERNOR_ROLE) {
        uint8 prev = uint8(state);
        state = VaultState.Idle;
        stateSince = uint64(block.timestamp);
        emit StateChanged(prev, uint8(state));
    }

    // --- Governor transfer ---
    function proposeGovernor(address newGov) external onlyRole(GOVERNOR_ROLE) {
        require(newGov != address(0), "ZERO_GOV");
        pendingGovernor = newGov;
    }

    function acceptGovernor() external {
        require(msg.sender == pendingGovernor, "NOT_PENDING");
        address prev = governor;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNOR_ROLE, msg.sender);
        _revokeRole(GOVERNOR_ROLE, prev);
        _revokeRole(DEFAULT_ADMIN_ROLE, prev);
        governor = msg.sender;
        pendingGovernor = address(0);
    }

    /// @notice Sets the local withdrawal buffer in basis points.
    function setWithdrawalBufferBps(uint16 bps) external onlyRole(GOVERNOR_ROLE) {
        require(bps <= 10_000, "BPS");
        withdrawalBufferBps = bps;
    }

    /// @notice Configure the per-epoch outflow cap and epoch length.
    function setEpochOutflowConfig(uint16 capBps, uint64 lengthSec) external onlyRole(GOVERNOR_ROLE) {
        require(capBps <= 10_000, "BPS");
        require(lengthSec > 0, "LEN");
        epochOutflowCapBps = capBps;
        epochLengthSec = lengthSec;
    }

    // --- Internal: sync before share math ---
    /// @dev Intentionally empty hook to keep share math deterministic pre-mint.
    /// In more complex vaults, this may read adapter TVLs or accrue yield before mint/burn.
    function _preMintSync() internal view {
        // no-op in this implementation (read-only); left for pattern consistency.
    }

    // --- ERC4626 virtual conversions ---
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 tAssets = super.totalAssets() + VIRTUAL_ASSETS;
        uint256 tSupply = totalSupply() + VIRTUAL_SHARES;
        if (assets == 0) return 0;
        return Math.mulDiv(assets, tSupply, tAssets, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 tAssets = super.totalAssets() + VIRTUAL_ASSETS;
        uint256 tSupply = totalSupply() + VIRTUAL_SHARES;
        if (shares == 0) return 0;
        return Math.mulDiv(shares, tAssets, tSupply, rounding);
    }

    // --- ERC4626 overrides ---
    /// @inheritdoc ERC4626Upgradeable
    function deposit(uint256 assets, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        if (!depositsEnabled) revert DepositsDisabled();
        _preMintSync();
        shares = super.deposit(assets, receiver);
        // Mint LST mirror to receiver equal to shares
        lst.mint(receiver, shares);
        emit LstMinted(receiver, shares, address(lst));
    }

    /// @inheritdoc ERC4626Upgradeable
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        // Burn LST first, then shares
        lst.burn(owner, shares);
        emit LstBurned(owner, shares, address(lst));
        _preMintSync();
        assets = super.redeem(shares, receiver, owner);
    }

    // --- Strategy operations ---
    function allocateToAdapter(address adapter, uint256 assets, bytes calldata data)
        external
        onlyRole(REBALANCER_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (state != VaultState.Idle) revert BadState();
        state = VaultState.Allocating;
        stateSince = uint64(block.timestamp);
        emit StateChanged(uint8(VaultState.Idle), uint8(state));
        if (!adapterRegistry.isAllowed(adapter)) revert NotAllowedAdapter();
        uint256 cap = adapterRegistry.capOf(adapter);
        // Enforce cap against current adapter allocation
        uint256 current = IAdapterLike(adapter).totalAssets();
        if (current + assets > cap) revert CapExceeded();
        // Move assets to adapter before invoking deposit to prevent reentrancy games on allowance
        IERC20(asset()).safeTransfer(adapter, assets);
        (bool ok,) = adapter.call(abi.encodeWithSignature("deposit(uint256,bytes)", assets, data));
        require(ok, "ADAPTER_DEPOSIT_FAIL");
        emit AdapterAllocated(adapter, asset(), assets);
        state = VaultState.Idle;
        stateSince = uint64(block.timestamp);
        emit StateChanged(uint8(VaultState.Allocating), uint8(state));
    }

    function deallocateFromAdapter(address adapter, uint256 assets, bytes calldata data)
        external
        onlyRole(REBALANCER_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (state != VaultState.Idle) revert BadState();
        state = VaultState.Deallocating;
        stateSince = uint64(block.timestamp);
        emit StateChanged(uint8(VaultState.Idle), uint8(state));
        (bool ok,) = adapter.call(abi.encodeWithSignature("withdraw(uint256,bytes)", assets, data));
        require(ok, "ADAPTER_WITHDRAW_FAIL");
        emit AdapterDeallocated(adapter, asset(), assets);
        state = VaultState.Idle;
        stateSince = uint64(block.timestamp);
        emit StateChanged(uint8(VaultState.Deallocating), uint8(state));
    }

    function harvestAdapter(address adapter, bytes calldata data)
        external
        onlyRole(REBALANCER_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (state != VaultState.Idle) revert BadState();
        state = VaultState.Harvesting;
        stateSince = uint64(block.timestamp);
        emit StateChanged(uint8(VaultState.Idle), uint8(state));
        (bool ok,) = adapter.call(abi.encodeWithSignature("harvest(bytes)", data));
        require(ok, "ADAPTER_HARVEST_FAIL");
        emit Harvest(adapter, asset(), 0);
        state = VaultState.Idle;
        stateSince = uint64(block.timestamp);
        emit StateChanged(uint8(VaultState.Harvesting), uint8(state));
    }

    // --- Withdraw queue (harness) ---
    /// @notice Enqueue a withdraw request in shares units. Emits WithdrawQueued.
    function enqueueWithdraw(uint256 shares) external whenNotPaused returns (uint256 claimId) {
        require(shares > 0, "ZERO_SHARES");
        // Compute unique claim id to avoid same-block collisions
        uint256 nonce = ++_claimNonce;
        claimId = uint256(
            keccak256(
                abi.encodePacked(block.chainid, address(this), msg.sender, shares, nonce, bytes32(0), block.timestamp)
            )
        );
        claims[claimId] = Claim({
            user: msg.sender,
            shares: uint128(shares),
            filledAssets: 0,
            active: true,
            ts: uint64(block.timestamp)
        });
        emit WithdrawQueued(msg.sender, claimId, shares, block.timestamp);
    }

    /// @notice Enqueue or aggregate a withdraw request keyed by (user, actionId, epoch).
    function enqueueWithdraw(uint256 shares, bytes32 actionId) external whenNotPaused returns (uint256 claimId) {
        require(shares > 0, "ZERO_SHARES");
        uint64 epoch = epochLengthSec == 0 ? 0 : uint64(block.timestamp / epochLengthSec);
        uint256 existing = _epochClaimOf[epoch][msg.sender][actionId];
        if (existing != 0 && claims[existing].active) {
            // aggregate into existing claim
            Claim storage c = claims[existing];
            c.shares = uint128(uint256(c.shares) + shares);
            claimId = existing;
        } else {
            uint256 nonce = ++_claimNonce;
            claimId = uint256(
                keccak256(
                    abi.encodePacked(block.chainid, address(this), msg.sender, shares, nonce, actionId, block.timestamp)
                )
            );
            claims[claimId] = Claim({
                user: msg.sender,
                shares: uint128(shares),
                filledAssets: 0,
                active: true,
                ts: uint64(block.timestamp)
            });
            _epochClaimOf[epoch][msg.sender][actionId] = claimId;
            emit WithdrawQueued(msg.sender, claimId, shares, block.timestamp);
        }
    }

    /// @notice Fulfill a portion of a queued withdraw in asset units. Only HUB may call in tests/harness.
    function fulfillWithdraw(uint256 claimId, uint256 assets, bytes32 actionId)
        external
        onlyRole(HUB_ROLE)
        whenNotPaused
    {
        _fulfillWithdrawCore(claimId, assets, actionId);
    }

    function _fulfillWithdrawCore(uint256 claimId, uint256 assets, bytes32 actionId) internal {
        Claim storage c = claims[claimId];
        require(c.active, "INACTIVE");
        // Idempotency on (actionId, claimId)
        bytes32 key = keccak256(abi.encodePacked(actionId, claimId));
        if (_fulfilledAction[key]) revert NonceUsed(key);
        // Enforce epoch outflow cap
        if (epochLengthSec != 0 && epochOutflowCapBps != 0) {
            uint64 epoch = uint64(block.timestamp / epochLengthSec);
            uint256 tvl = totalAssets();
            uint256 cap = (tvl * uint256(epochOutflowCapBps)) / 10_000;
            uint256 sofar = epochOutflow[epoch];
            if (sofar + assets > cap) revert CapExceeded();
            epochOutflow[epoch] = sofar + assets;
        }
        // transfer assets to user up to local balance
        IERC20(asset()).safeTransfer(c.user, assets);
        unchecked {
            c.filledAssets += uint128(assets);
        }
        // if fully satisfied in assets terms, mark inactive
        uint256 targetAssets = convertToAssets(c.shares);
        if (c.filledAssets >= targetAssets) {
            c.active = false;
        }
        _fulfilledAction[key] = true;
        emit WithdrawFulfilled(c.user, claimId, assets, actionId, block.timestamp);
    }

    /// @notice Batch fulfill multiple withdraw claims; rejects duplicate claimIds within the call.
    function fulfillWithdrawBatch(uint256[] calldata claimIds, uint256[] calldata assets, bytes32 actionId)
        external
        onlyRole(HUB_ROLE)
        whenNotPaused
    {
        if (claimIds.length != assets.length) revert InvalidArray();
        // dedupe check using memory bitmap (simple quadratic due to small sizes in tests)
        for (uint256 i = 0; i < claimIds.length; i++) {
            for (uint256 j = i + 1; j < claimIds.length; j++) {
                if (claimIds[i] == claimIds[j]) revert DuplicateClaim();
            }
        }
        for (uint256 i = 0; i < claimIds.length; i++) {
            _fulfillWithdrawCore(claimIds[i], assets[i], actionId);
        }
    }

    // --- Hub handlers ---
    function onRemoteCredit(address user, uint256 assets, uint256 shares, uint256 nonce, bytes32 actionId)
        external
        onlyRole(HUB_ROLE)
        whenNotPaused
    {
        if (!bridgeEnabled) revert BridgeDisabled();
        // Idempotency guard per (vault, nonce)
        bytes32 n = keccak256(abi.encodePacked(address(this), nonce));
        if (_usedNonce[n]) revert NonceUsed(n);
        _usedNonce[n] = true;
        // Credit shares and mirror LST
        _preMintSync();
        _deposit(user, user, assets, shares);
        lst.mint(user, shares);
        emit RemoteCreditHandled(user, asset(), assets, shares, nonce, actionId);
    }

    function requestRemoteLiquidity(address toUser, uint256 assets) external onlyRole(HUB_ROLE) whenNotPaused {
        // Serve from local buffer regardless of bridge flag; if bridge is disabled and insufficient buffer, fail fast
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 tvl = totalAssets();
        uint256 maxLocal = (tvl * withdrawalBufferBps) / 10_000;
        bool served = false;
        if (assets <= bal && assets <= maxLocal) {
            // Enforce epoch outflow cap on fast path as well
            if (epochLengthSec != 0 && epochOutflowCapBps != 0) {
                uint64 epoch = uint64(block.timestamp / epochLengthSec);
                uint256 cap = (tvl * uint256(epochOutflowCapBps)) / 10_000;
                uint256 sofar = epochOutflow[epoch];
                if (sofar + assets > cap) revert CapExceeded();
                epochOutflow[epoch] = sofar + assets;
            }
            IERC20(asset()).safeTransfer(toUser, assets);
            served = true;
            bytes32 actionId = keccak256(
                abi.encode(
                    "RemoteLiquidity",
                    uint256(1),
                    block.chainid,
                    msg.sender,
                    block.chainid,
                    address(this),
                    toUser,
                    asset(),
                    assets,
                    uint256(block.number)
                )
            );
            emit RemoteLiquidityServed(toUser, asset(), assets, actionId);
        } else {
            // Not enough local buffer; if bridge disabled, revert; otherwise, a cross-chain transfer would occur off-chain so no event here
            if (!bridgeEnabled) revert InsufficientBuffer();
        }
    }

    // --- Borrow/Liquidation hooks ---
    function payOutBorrow(address to, address asset_, uint256 amount)
        external
        onlyRole(CONTROLLER_ROLE)
        whenNotPaused
    {
        IERC20(asset_).safeTransfer(to, amount);
        bytes32 actionId = keccak256(
            abi.encode(
                "BorrowPayout",
                uint256(1),
                block.chainid,
                msg.sender,
                block.chainid,
                address(this),
                to,
                asset_,
                amount,
                uint256(block.number)
            )
        );
        emit BorrowPayout(to, asset_, amount, actionId, block.timestamp);
    }

    function onSeizeShares(address user, uint256 shares, address to) external onlyRole(CONTROLLER_ROLE) {
        // Burn user's LST mirror shares
        lst.burn(user, shares);
        // Transfer ERC4626 shares from user to liquidator destination
        _transfer(user, to, shares);
        bytes32 actionId = keccak256(
            abi.encode(
                "SeizeShares",
                uint256(1),
                block.chainid,
                msg.sender,
                block.chainid,
                address(this),
                user,
                asset(),
                shares,
                uint256(block.number)
            )
        );
        emit SharesSeized(user, to, shares, actionId);
    }

    uint256[50] private __gap;
}
