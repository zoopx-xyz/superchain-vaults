// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceOracleRouter} from "../interfaces/IPriceOracleRouter.sol";
import {ISpokeYieldVault} from "../interfaces/ISpokeYieldVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ControllerHub
/// @notice Lending/borrowing controller hub with RAY fixed-point math and kinked IRM.
contract ControllerHub is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeCast for uint256;

    // Roles
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    // Constants
    uint256 public constant RAY = 1e27;
    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;

    struct MarketParams {
        uint16 ltvBps;
        uint16 liqThresholdBps;
        uint16 reserveFactorBps;
        uint128 borrowCap;
        uint16 kinkBps; // utilization kink in bps
        uint128 slope1Ray; // per-second rate in ray below kink
        uint128 slope2Ray; // per-second rate in ray above kink
        uint128 baseRateRay; // per-second base rate
        address lst; // collateral LST token associated for this market
        address vault; // spoke vault to seize shares on
    }

    struct MarketState {
        uint256 supplyIndexRay;
        uint256 debtIndexRay;
        uint40 lastAccrual;
        uint216 totalBorrows; // in asset units
        uint216 totalReserves; // in asset units
    }

    // Per market and user storage
    mapping(address => MarketParams) public marketParams; // asset => params
    mapping(address => MarketState) public marketState; // asset => state
    mapping(address => mapping(address => bool)) public isEntered; // user => lst => entered as collateral
    mapping(address => mapping(address => uint256)) public debtPrincipal; // user => asset => principal amount
    mapping(address => mapping(address => uint256)) public debtIndexSnapshot; // user => asset => debt index at last update
    // Market enumeration for production multi-market accounting
    address[] private _markets;
    mapping(address => bool) public isMarket;

    // External dependencies
    IPriceOracleRouter public oracle;

    // Events
    event MarketListed(
        address indexed asset,
        uint16 ltvBps,
        uint16 liqThresholdBps,
        uint16 reserveFactorBps,
        uint16 kinkBps,
        uint64 baseRateRayPerSec,
        uint64 slope1RayPerSec,
        uint64 slope2RayPerSec,
        uint256 borrowCap
    );
    event MarketParamsUpdated(
        address indexed asset,
        uint16 ltvBps,
        uint16 liqThresholdBps,
        uint16 reserveFactorBps,
        uint16 kinkBps,
        uint64 baseRateRayPerSec,
        uint64 slope1RayPerSec,
        uint64 slope2RayPerSec,
        uint256 borrowCap
    );
    event Accrued(
        address indexed asset,
        uint256 supplyIndexRay,
        uint256 debtIndexRay,
        uint256 totalBorrows,
        uint256 totalReserves,
        uint256 timestamp
    );
    event EnterMarket(address indexed user, address indexed lst);
    event ExitMarket(address indexed user, address indexed lst);
    // KPI/events for off-chain observability and tests
    event BorrowRequested(
        address indexed user, address indexed asset, uint256 amount, uint256 dstChainId, bytes32 actionId, uint256 ts
    );
    event BorrowDecision(
        address indexed user, address indexed asset, uint256 amount, uint8 routesUsed, bytes32 actionId, uint256 ts
    );
    event IRMRateUpdated(address indexed asset, uint256 newBorrowRateRayPerSec, uint256 utilizationRay, uint256 ts);
    event BorrowPaused(address indexed asset, uint256 ts);
    event Borrow(
        address indexed user,
        address indexed asset,
        uint256 amount,
        uint256 debtIndexRay,
        uint256 hfBps,
        uint256 dstChainId,
        bytes32 actionId
    );
    event Repay(
        address indexed user,
        address indexed asset,
        uint256 amount,
        uint256 debtIndexRay,
        uint256 srcChainId,
        bytes32 actionId
    );
    event Liquidate(
        address indexed liquidator,
        address indexed user,
        address indexed repayAsset,
        uint256 repayAmount,
        address seizeLst,
        uint256 seizeShares,
        uint256 discountBps,
        bytes32 actionId
    );
    event BorrowCapSet(address indexed asset, uint256 cap);
    event PauseSet(bool deposits, bool borrows, bool bridge, bool liquidations);
    event GovernorProposed(address indexed currentGovernor, address indexed pendingGovernor);
    event GovernorAccepted(address indexed previousGovernor, address indexed newGovernor);

    // Errors
    error MarketNotListed();
    error InvalidParams();
    error ExceedsBorrowCap();
    error InsufficientCollateral();
    error NotEnteredMarket();

    struct Liq {
        uint256 priceLst;
        uint256 priceAsset;
        uint256 ar;
        uint256 shares;
    }
    // Policy constants

    uint256 public constant CLOSE_FACTOR_BPS = 5000; // 50%
    uint256 public constant LIQ_BONUS_BPS = 1000; // 10%

    // Pause flags
    bool public borrowsPaused;
    bool public liquidationsPaused;
    address public governor;
    address public pendingGovernor;

    /// @notice Set borrow or liquidation pause flags.
    function setPause(bool _borrows, bool _liquidations) external onlyRole(GOVERNOR_ROLE) {
        borrowsPaused = _borrows;
        liquidationsPaused = _liquidations;
        emit PauseSet(false, _borrows, false, _liquidations);
        if (_borrows) {
            // Global pause (asset-less); emit with zero address for compatibility
            emit BorrowPaused(address(0), block.timestamp);
        }
    }

    // ---------------- internal helpers ----------------
    function _price1e18(address asset) internal view returns (uint256 price1e18) {
        (uint256 price, uint8 dec,) = oracle.getPrice(asset);
        if (dec == 18) return price;
        if (dec < 18) return price * (10 ** (18 - dec));
        return price / (10 ** (dec - 18));
    }

    function _actionId(string memory msgType, address user, address asset, uint256 amount, uint256 nonce)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                msgType,
                uint256(1),
                block.chainid,
                address(this),
                block.chainid,
                address(this),
                user,
                asset,
                amount,
                nonce
            )
        );
    }

    /// @notice Decrease user debt by a repay amount in asset units; rounds in principal space and converts back to assets.
    function _decreaseDebt(address user, address asset, uint256 idxRay, uint256 repayAmountAsset)
        internal
        returns (uint256 actualRepaidAsset)
    {
        MarketState storage s = marketState[asset];
        uint256 rp = (repayAmountAsset * RAY) / idxRay; // repay principal units
        uint256 princ = debtPrincipal[user][asset];
        if (rp > princ) rp = princ;
        debtPrincipal[user][asset] = princ - rp;
        debtIndexSnapshot[user][asset] = idxRay;
        // convert capped rp back to asset units as actual repaid
        actualRepaidAsset = Math.mulDiv(rp, idxRay, RAY);
        uint256 tb = s.totalBorrows;
        if (actualRepaidAsset > tb) actualRepaidAsset = tb;
        s.totalBorrows = SafeCast.toUint216(tb - actualRepaidAsset);
    }

    function _increaseDebt(address user, address asset, uint256 amount) internal returns (uint256 newPrincipal) {
        MarketState storage s = marketState[asset];
        uint256 idx = s.debtIndexRay;
        uint256 addPrincipal = (amount * RAY) / idx;
        newPrincipal = debtPrincipal[user][asset] + addPrincipal;
        debtPrincipal[user][asset] = newPrincipal;
        debtIndexSnapshot[user][asset] = idx;
    }

    function _isBorrowAllowed(address user, address asset, uint256 amount) internal view returns (bool) {
        MarketParams storage p = marketParams[asset];
        if (!isEntered[user][p.lst]) return false;
        uint256 lstBal = IERC20(p.lst).balanceOf(user);
        uint256 priceLst1e18 = _price1e18(p.lst);
        uint256 priceAsset1e18 = _price1e18(asset);
        uint256 collValueWad = Math.mulDiv(lstBal, priceLst1e18, 1e18);
        uint256 curDebt = currentDebt(user, asset);
        uint256 curDebtValueWad = Math.mulDiv(curDebt, priceAsset1e18, 1e18);
        uint256 addDebtValueWad = Math.mulDiv(amount, priceAsset1e18, 1e18);
        uint256 maxDebtWad = (collValueWad * uint256(p.ltvBps)) / BPS;
        return curDebtValueWad + addDebtValueWad <= maxDebtWad;
    }

    function initialize(address initialGovernor, address oracle_) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, initialGovernor);
        _grantRole(GOVERNOR_ROLE, initialGovernor);
        oracle = IPriceOracleRouter(oracle_);
        governor = initialGovernor;
    }

    function _authorizeUpgrade(address) internal override onlyRole(GOVERNOR_ROLE) {}

    // --- Two-step governor ---
    function proposeGovernor(address newGov) external onlyRole(GOVERNOR_ROLE) {
        if (newGov == address(0)) revert InvalidParams();
        pendingGovernor = newGov;
        emit GovernorProposed(governor, newGov);
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
        emit GovernorAccepted(prev, msg.sender);
    }

    // Admin: list market
    function listMarket(address asset, bytes calldata params) external onlyRole(GOVERNOR_ROLE) {
        MarketParams memory p = abi.decode(params, (MarketParams));
        // Policy bounds: LTV < LT; kink within [1000, 9500]; close factor/bonus constants already bounded; slope/base rays must be reasonable.
        if (asset == address(0) || p.lst == address(0)) revert InvalidParams();
        if (p.liqThresholdBps <= p.ltvBps) revert InvalidParams();
        if (p.kinkBps < 1000 || p.kinkBps > 9500) revert InvalidParams();
        if (CLOSE_FACTOR_BPS > 5000) revert InvalidParams();
        if (LIQ_BONUS_BPS > 1000) revert InvalidParams();
        if (p.kinkBps < 1000 || p.kinkBps > 9500) revert InvalidParams();
        // Reserve factor ≤ 50%
        if (p.reserveFactorBps > 5000) revert InvalidParams();
        // Nonzero indices params
        if (p.slope2Ray < p.slope1Ray) revert InvalidParams();
        marketParams[asset] = p;
        if (!isMarket[asset]) {
            isMarket[asset] = true;
            _markets.push(asset);
        }
        marketState[asset] = MarketState({
            supplyIndexRay: RAY,
            debtIndexRay: RAY,
            lastAccrual: uint40(block.timestamp),
            totalBorrows: 0,
            totalReserves: 0
        });
        emit MarketListed(
            asset,
            p.ltvBps,
            p.liqThresholdBps,
            p.reserveFactorBps,
            p.kinkBps,
            uint64(p.baseRateRay),
            uint64(p.slope1Ray),
            uint64(p.slope2Ray),
            p.borrowCap
        );
    }

    // Admin: update params
    function setParams(address asset, bytes calldata params) external onlyRole(GOVERNOR_ROLE) {
        MarketParams memory p = abi.decode(params, (MarketParams));
        if (p.lst == address(0)) revert InvalidParams();
        if (p.liqThresholdBps <= p.ltvBps) revert InvalidParams();
        if (p.kinkBps < 1000 || p.kinkBps > 9500) revert InvalidParams();
        if (CLOSE_FACTOR_BPS > 5000) revert InvalidParams();
        if (LIQ_BONUS_BPS > 1000) revert InvalidParams();
        if (p.kinkBps < 1000 || p.kinkBps > 9500) revert InvalidParams();
        if (p.reserveFactorBps > 5000) revert InvalidParams();
        if (p.slope2Ray < p.slope1Ray) revert InvalidParams();
        marketParams[asset] = p;
        emit MarketParamsUpdated(
            asset,
            p.ltvBps,
            p.liqThresholdBps,
            p.reserveFactorBps,
            p.kinkBps,
            uint64(p.baseRateRay),
            uint64(p.slope1Ray),
            uint64(p.slope2Ray),
            p.borrowCap
        );
    }

    // Collateral: enable LST as collateral
    function enterMarket(address lst) external {
        isEntered[msg.sender][lst] = true;
        emit EnterMarket(msg.sender, lst);
    }

    function exitMarket(address lst) external {
        // Block exit when unhealthy
        uint256 hf = healthFactor(msg.sender);
        require(hf >= 1e18, "UNHEALTHY");
        isEntered[msg.sender][lst] = false;
        emit ExitMarket(msg.sender, lst);
    }

    // Accrual for a specific market
    function accrue(address asset) public {
        MarketState storage s = marketState[asset];
        MarketParams storage p = marketParams[asset];
        if (s.lastAccrual == 0) revert MarketNotListed();
        uint256 last = s.lastAccrual;
        if (block.timestamp == last) return;
        uint256 dt = block.timestamp - last;

        // Utilization estimation: U = totalBorrows / (totalBorrows + 1) to avoid div by zero (no on-chain cash accounting here)
        uint256 borrows = uint256(s.totalBorrows);
        uint256 utilizationRay = borrows == 0 ? 0 : (borrows * RAY) / (borrows + 1);

        // Borrow rate per second (ray)
        uint256 rateRay;
        if (utilizationRay <= (uint256(p.kinkBps) * RAY) / BPS) {
            rateRay =
                uint256(p.baseRateRay) + (uint256(p.slope1Ray) * utilizationRay) / ((uint256(p.kinkBps) * RAY) / BPS);
        } else {
            uint256 over = utilizationRay - ((uint256(p.kinkBps) * RAY) / BPS);
            uint256 denom = RAY - ((uint256(p.kinkBps) * RAY) / BPS);
            rateRay = uint256(p.baseRateRay) + uint256(p.slope1Ray) + (uint256(p.slope2Ray) * over) / denom;
        }

        // Linearized index growth: idx = idx * (1 + rate*dt)
        uint256 deltaRay = rateRay * dt;
        s.debtIndexRay = (s.debtIndexRay * (RAY + deltaRay)) / RAY;
        // Supply index approximate with utilization and reserve factor
        uint256 rf = uint256(p.reserveFactorBps);
        uint256 supplyRateRay = (rateRay * utilizationRay * (BPS - rf)) / (RAY * BPS);
        uint256 supplyDeltaRay = supplyRateRay * dt;
        s.supplyIndexRay = (s.supplyIndexRay * (RAY + supplyDeltaRay)) / RAY;

        s.lastAccrual = uint40(block.timestamp);
        emit IRMRateUpdated(asset, rateRay, utilizationRay, block.timestamp);
        emit Accrued(asset, s.supplyIndexRay, s.debtIndexRay, s.totalBorrows, s.totalReserves, block.timestamp);
    }

    // Compute current user debt in asset units
    function currentDebt(address user, address asset) public view returns (uint256) {
        MarketState storage s = marketState[asset];
        if (s.lastAccrual == 0) return 0;
        uint256 principal = debtPrincipal[user][asset];
        if (principal == 0) return 0;
        uint256 snapshot = debtIndexSnapshot[user][asset];
        if (snapshot == 0) snapshot = RAY;
        return (principal * s.debtIndexRay) / snapshot;
    }

    /// @notice Compute account health factor across all listed markets.
    /// HF = (Σ_i price(lst_i) * balance(lst_i) * LT_i / 1e4) / (Σ_j price(asset_j) * debt_j)
    /// Returns 1e18 when no debt.
    function healthFactor(address user) public view returns (uint256 hfWad) {
        (uint256 coll, uint256 debt,) = accountLiquidity(user);
        if (debt == 0) return 1e18;
        return Math.mulDiv(coll, 1e18, debt);
    }

    /// @notice Returns (collateralValueWad, debtValueWad, shortfallWad) across all markets.
    function accountLiquidity(address user)
        public
        view
        returns (uint256 collateralValueWad, uint256 debtValueWad, uint256 shortfallWad)
    {
        uint256 mlen = _markets.length;
        for (uint256 i = 0; i < mlen; i++) {
            address asset = _markets[i];
            MarketParams storage p = marketParams[asset];
            if (p.lst != address(0) && isEntered[user][p.lst]) {
                uint256 lstBal = IERC20(p.lst).balanceOf(user);
                uint256 priceLst1e18 = _price1e18(p.lst);
                uint256 collWad = Math.mulDiv(lstBal, priceLst1e18, 1e18);
                collateralValueWad += (collWad * uint256(p.liqThresholdBps)) / BPS;
            }
        }
        for (uint256 i = 0; i < mlen; i++) {
            address asset = _markets[i];
            uint256 d = currentDebt(user, asset);
            if (d != 0) {
                uint256 priceAsset1e18 = _price1e18(asset);
                debtValueWad += Math.mulDiv(d, priceAsset1e18, 1e18);
            }
        }
        if (debtValueWad > collateralValueWad) shortfallWad = debtValueWad - collateralValueWad;
        else shortfallWad = 0;
    }

    // Borrow increases user's debt and emits instruction to payout cross-chain
    function borrow(address asset, uint256 amount, uint256 dstChainId) external nonReentrant whenNotPaused {
        if (borrowsPaused) revert InsufficientCollateral(); // reuse error; alternatively define Paused
        accrue(asset);
        MarketParams storage p = marketParams[asset];
        if (marketState[asset].lastAccrual == 0) revert MarketNotListed();

        // Collateral check using LTV and oracle prices
        if (!_isBorrowAllowed(msg.sender, asset, amount)) revert InsufficientCollateral();

        // Emit borrow request intent prior to routing/decision
        bytes32 reqAid = _actionId("BorrowRequested", msg.sender, asset, amount, block.number);
        emit BorrowRequested(msg.sender, asset, amount, dstChainId, reqAid, block.timestamp);

        // Cap enforcement and state updates
        MarketState storage s = marketState[asset];
        uint256 newTotalBorrows = uint256(s.totalBorrows) + amount;
        if (newTotalBorrows > uint256(p.borrowCap)) revert ExceedsBorrowCap();
        s.totalBorrows = SafeCast.toUint216(newTotalBorrows);

        // Global HF check: ensure user remains healthy (>=1) after proposed borrow
        // Approximate by checking current HF; exact projection requires simulating added debt in value terms.
        // We reuse per-asset LTV gate for precise per-market constraint and rely on HF for global risk.
        require(healthFactor(msg.sender) >= 1e18, "HF_LT_1");
        _increaseDebt(msg.sender, asset, amount);
        _emitBorrow(msg.sender, asset, amount, dstChainId);
        // Emit a decision with number of routes used (single route in current implementation)
        bytes32 decAid = _actionId("BorrowDecision", msg.sender, asset, amount, block.number);
        emit BorrowDecision(msg.sender, asset, amount, 1, decAid, block.timestamp);
        // Cross-chain payout is performed by relayers calling spoke vaults.
    }

    function _emitBorrow(address user, address asset, uint256 amount, uint256 dstChainId) internal {
        MarketParams storage p = marketParams[asset];
        uint256 idx = marketState[asset].debtIndexRay;
        uint256 priceLst1e18 = _price1e18(p.lst);
        uint256 priceAsset1e18 = _price1e18(asset);
        uint256 lstBal = IERC20(p.lst).balanceOf(user);
        uint256 collValueWad = Math.mulDiv(lstBal, priceLst1e18, 1e18);
        uint256 debtValueWad = Math.mulDiv(currentDebt(user, asset), priceAsset1e18, 1e18);
        uint256 hfBps = debtValueWad == 0 ? type(uint256).max : (collValueWad * BPS) / debtValueWad;
        bytes32 aid = _actionId("Borrow", user, asset, amount, block.number);
        emit Borrow(user, asset, amount, idx, hfBps, dstChainId, aid);
    }

    /// @notice Returns the list of all listed borrow markets (asset addresses).
    function allMarkets() external view returns (address[] memory) {
        return _markets;
    }

    // Repay reduces principal
    function repay(address asset, uint256 amount, uint256 srcChainId) external nonReentrant whenNotPaused {
        accrue(asset);
        MarketState storage s = marketState[asset];
        if (s.lastAccrual == 0) revert MarketNotListed();
        uint256 idx = s.debtIndexRay;
        uint256 principal = debtPrincipal[msg.sender][asset];
        if (principal == 0) return;
        uint256 repayPrincipal = (amount * RAY) / idx;
        if (repayPrincipal > principal) repayPrincipal = principal;
        debtPrincipal[msg.sender][asset] = principal - repayPrincipal;
        debtIndexSnapshot[msg.sender][asset] = idx;
        uint256 newTotalBorrows = uint256(s.totalBorrows) - Math.min(amount, uint256(s.totalBorrows));
        s.totalBorrows = SafeCast.toUint216(newTotalBorrows);
        _emitRepay(msg.sender, asset, amount, srcChainId, idx);
    }

    function _emitRepay(address user, address asset, uint256 amount, uint256 srcChainId, uint256 idx) internal {
        emit Repay(user, asset, amount, idx, srcChainId, _actionId("Repay", user, asset, amount, block.number));
    }

    // Liquidation: repay on behalf and seize LST shares
    function liquidate(address user, address repayAsset, uint256 repayAmount, address seizeLst, address to)
        external
        nonReentrant
        whenNotPaused
    {
        if (liquidationsPaused) revert NotEnteredMarket();
        accrue(repayAsset);
        (uint256 ar, uint256 shares, address vaultAddr) =
            _quoteAndValidateLiquidation(user, repayAsset, repayAmount, seizeLst);
        _finalizeLiquidation(user, repayAsset, ar, seizeLst, vaultAddr, shares, to);
    }

    function _quoteAndValidateLiquidation(address user, address repayAsset, uint256 repayAmount, address seizeLst)
        internal
        view
        returns (uint256 ar, uint256 shares, address vaultAddr)
    {
        MarketParams storage p = marketParams[repayAsset];
        if (p.lst != seizeLst) revert InvalidParams();
        uint256 d = currentDebt(user, repayAsset);
        if (d == 0) revert InsufficientCollateral();
        if (!isEntered[user][seizeLst]) revert NotEnteredMarket();

        uint256 priceLst = _price1e18(seizeLst);
        uint256 priceAsset = _price1e18(repayAsset);
        uint256 collWad = Math.mulDiv(IERC20(seizeLst).balanceOf(user), priceLst, 1e18);
        uint256 debtWad = Math.mulDiv(d, priceAsset, 1e18);
        uint256 liqLimit = (collWad * uint256(p.liqThresholdBps)) / BPS;
        if (debtWad <= liqLimit) revert InsufficientCollateral();

        ar = Math.min(repayAmount, (d * CLOSE_FACTOR_BPS) / BPS);
        uint256 repayValueWad = Math.mulDiv(ar, priceAsset, 1e18);
        uint256 seizeValueWad = (repayValueWad * (10_000 + LIQ_BONUS_BPS)) / BPS;
        // Round up to ensure the protocol does not under-seize due to truncation when converting value to shares
        uint256 num = Math.mulDiv(seizeValueWad, 1e18, 1); // keep precision
        shares = Math.ceilDiv(num, priceLst);
        vaultAddr = p.vault;
    }

    function _finalizeLiquidation(
        address user,
        address repayAsset,
        uint256 ar,
        address seizeLst,
        address vaultAddr,
        uint256 shares,
        address to
    ) internal {
        // Seize shares first to prevent DoS when no local cash on spoke
        ISpokeYieldVault(vaultAddr).onSeizeShares(user, shares, to);
        // Attempt to reduce debt immediately; if there is insufficient local cash on spoke to honor bridge payouts,
        // this hub still accounts for debt reduction by the repaid amount provided by the liquidator off-chain.
        // For cross-chain settlement, the spoke vault can be instructed to bridge liquidity asynchronously.
        uint256 idxRay = marketState[repayAsset].debtIndexRay;
        uint256 actualRepaid = _decreaseDebt(user, repayAsset, idxRay, ar);
        _emitLiquidate(msg.sender, user, repayAsset, actualRepaid, seizeLst, shares);
    }

    function _emitLiquidate(
        address liquidator,
        address user,
        address repayAsset,
        uint256 actualRepaid,
        address seizeLst,
        uint256 shares
    ) internal {
        bytes32 aid = _actionId("Liquidate", user, repayAsset, actualRepaid, block.number);
        emit Liquidate(liquidator, user, repayAsset, actualRepaid, seizeLst, shares, LIQ_BONUS_BPS, aid);
    }

    /// @notice Set borrow cap for a market.
    function setBorrowCap(address asset, uint256 cap) external onlyRole(GOVERNOR_ROLE) {
        marketParams[asset].borrowCap = SafeCast.toUint128(cap);
        emit BorrowCapSet(asset, cap);
    }

    /// @notice Returns account liquidity info: collateral value, debt value, and shortfall (if any), all in 1e18 precision.
    function accountLiquidity(address user, address asset)
        public
        view
        returns (uint256 collateralWad, uint256 debtWad, uint256 shortfallWad)
    {
        MarketParams storage p = marketParams[asset];
        uint256 priceLst1e18 = _price1e18(p.lst);
        uint256 priceAsset1e18 = _price1e18(asset);
        uint256 lstBal = IERC20(p.lst).balanceOf(user);
        collateralWad = Math.mulDiv(lstBal, priceLst1e18, 1e18);
        debtWad = Math.mulDiv(currentDebt(user, asset), priceAsset1e18, 1e18);
        uint256 liqLimit = (collateralWad * uint256(p.liqThresholdBps)) / BPS;
        shortfallWad = debtWad > liqLimit ? debtWad - liqLimit : 0;
    }

    /// @notice Returns market state and derived utilization for an asset.
    function marketStateExtended(address asset)
        external
        view
        returns (MarketState memory s, MarketParams memory p, uint256 utilizationRay)
    {
        s = marketState[asset];
        p = marketParams[asset];
        uint256 borrows = uint256(s.totalBorrows);
        utilizationRay = borrows == 0 ? 0 : (borrows * RAY) / (borrows + 1);
    }

    uint256[50] private __gap;
}
