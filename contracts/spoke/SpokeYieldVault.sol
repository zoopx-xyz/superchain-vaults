// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
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
    event RemoteCreditHandled(address indexed user, address indexed asset, uint256 assets, uint256 shares, uint256 nonce, bytes32 actionId);
    event RemoteLiquidityServed(address indexed toUser, address indexed asset, uint256 assets, bytes32 actionId);
    event BorrowPayout(address indexed to, address indexed asset, uint256 amount, bytes32 actionId);
    event SharesSeized(address indexed user, address indexed to, uint256 shares, bytes32 actionId);
    event FlagsUpdated(bool depositsEnabled, bool borrowsEnabled, bool bridgeEnabled);

    // Errors
    error DepositsDisabled();
    error BorrowsDisabled();
    error BridgeDisabled();
    error NotAllowedAdapter();
    error CapExceeded();
    error NonceUsed(bytes32);
    error InsufficientBuffer();

    // Nonce replay protection for inbound messages
    mapping(bytes32 => bool) private _usedNonce;

    function initialize(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address hub_,
        address governor,
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
        _grantRole(DEFAULT_ADMIN_ROLE, governor);
        _grantRole(GOVERNOR_ROLE, governor);
        _grantRole(REBALANCER_ROLE, rebalancer);
        depositsEnabled = true;
        bridgeEnabled = true;
        _grantRole(HUB_ROLE, hub_);
    }

    function _authorizeUpgrade(address) internal override onlyRole(GOVERNOR_ROLE) {}

    // --- Flags ---
    function setFlags(bool _deposits, bool _borrows, bool _bridge) external onlyRole(GOVERNOR_ROLE) {
        depositsEnabled = _deposits;
        borrowsEnabled = _borrows;
        bridgeEnabled = _bridge;
        emit FlagsUpdated(_deposits, _borrows, _bridge);
    }

    /// @notice Sets the local withdrawal buffer in basis points.
    function setWithdrawalBufferBps(uint16 bps) external onlyRole(GOVERNOR_ROLE) {
        require(bps <= 10_000, "BPS");
        withdrawalBufferBps = bps;
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
        assets = super.redeem(shares, receiver, owner);
    }

    // --- Strategy operations ---
    function allocateToAdapter(address adapter, uint256 assets, bytes calldata data)
        external
        onlyRole(REBALANCER_ROLE)
        nonReentrant
    {
        if (!adapterRegistry.isAllowed(adapter)) revert NotAllowedAdapter();
        uint256 cap = adapterRegistry.capOf(adapter);
        // Enforce cap against current adapter allocation
        uint256 current = IAdapterLike(adapter).totalAssets();
        if (current + assets > cap) revert CapExceeded();
        // Move assets to adapter before invoking deposit to prevent reentrancy games on allowance
        IERC20(asset()).safeTransfer(adapter, assets);
        (bool ok, ) = adapter.call(abi.encodeWithSignature("deposit(uint256,bytes)", assets, data));
        require(ok, "ADAPTER_DEPOSIT_FAIL");
    emit AdapterAllocated(adapter, asset(), assets);
    }

    function deallocateFromAdapter(address adapter, uint256 assets, bytes calldata data)
        external
        onlyRole(REBALANCER_ROLE)
        nonReentrant
    {
        (bool ok, ) = adapter.call(abi.encodeWithSignature("withdraw(uint256,bytes)", assets, data));
        require(ok, "ADAPTER_WITHDRAW_FAIL");
    emit AdapterDeallocated(adapter, asset(), assets);
    }

    function harvestAdapter(address adapter, bytes calldata data)
        external
        onlyRole(REBALANCER_ROLE)
        nonReentrant
    {
        (bool ok, ) = adapter.call(abi.encodeWithSignature("harvest(bytes)", data));
        require(ok, "ADAPTER_HARVEST_FAIL");
    emit Harvest(adapter, asset(), 0);
    }

    // --- Hub handlers ---
    function onRemoteCredit(address user, uint256 assets, uint256 shares, uint256 nonce, bytes32 actionId) external onlyRole(HUB_ROLE) {
        if (!bridgeEnabled) revert BridgeDisabled();
        // Idempotency guard per (vault, nonce)
        bytes32 n = keccak256(abi.encodePacked(address(this), nonce));
        if (_usedNonce[n]) revert NonceUsed(n);
        _usedNonce[n] = true;
        // Credit shares and mirror LST
        _deposit(user, user, assets, shares);
        lst.mint(user, shares);
        emit RemoteCreditHandled(user, asset(), assets, shares, nonce, actionId);
    }

    function requestRemoteLiquidity(address toUser, uint256 assets) external onlyRole(HUB_ROLE) {
        // Serve from local buffer regardless of bridge flag; if bridge is disabled and insufficient buffer, fail fast
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 tvl = totalAssets();
        uint256 maxLocal = (tvl * withdrawalBufferBps) / 10_000;
        bool served = false;
        if (assets <= bal && assets <= maxLocal) {
            IERC20(asset()).safeTransfer(toUser, assets);
            served = true;
            bytes32 actionId = keccak256(abi.encode(
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
            ));
            emit RemoteLiquidityServed(toUser, asset(), assets, actionId);
        } else {
            // Not enough local buffer; if bridge disabled, revert; otherwise, a cross-chain transfer would occur off-chain so no event here
            if (!bridgeEnabled) revert InsufficientBuffer();
        }
    }

    // --- Borrow hooks (phase-2 reserved) ---
    function payOutBorrow(address to, address asset_, uint256 amount) external onlyRole(CONTROLLER_ROLE) whenNotPaused {
        IERC20(asset_).safeTransfer(to, amount);
        bytes32 actionId = keccak256(abi.encode("BorrowPayout", uint256(1), block.chainid, msg.sender, block.chainid, address(this), to, asset_, amount, uint256(block.number)));
        emit BorrowPayout(to, asset_, amount, actionId);
    }

    function onSeizeShares(address user, uint256 shares, address to) external onlyRole(CONTROLLER_ROLE) {
        // Burn user's LST mirror shares
        lst.burn(user, shares);
        // Transfer ERC4626 shares from user to liquidator destination
        _transfer(user, to, shares);
        bytes32 actionId = keccak256(abi.encode("SeizeShares", uint256(1), block.chainid, msg.sender, block.chainid, address(this), user, asset(), shares, uint256(block.number)));
        emit SharesSeized(user, to, shares, actionId);
    }

    uint256[50] private __gap;
}
