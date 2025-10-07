// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SpokeYieldVault} from "contracts/spoke/SpokeYieldVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SuperchainERC20} from "contracts/tokens/SuperchainERC20.sol";

contract MockAdapterRegistry {
    function isAllowed(address) external pure returns (bool) {
        return true;
    }

    function capOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }
}

contract MockAdapterRegistryVar {
    bool public allowed;
    uint256 public cap;

    constructor(bool a, uint256 c) {
        allowed = a;
        cap = c;
    }

    function set(bool a, uint256 c) external {
        allowed = a;
        cap = c;
    }

    function isAllowed(address) external view returns (bool) {
        return allowed;
    }

    function capOf(address) external view returns (uint256) {
        return cap;
    }
}

contract MockAdapterTarget {
    event DepositCalled(uint256 assets, bytes data);
    event WithdrawCalled(uint256 assets, bytes data);
    event HarvestCalled(bytes data);

    function totalAssets() external pure returns (uint256) {
        return 0;
    }

    function deposit(uint256 assets, bytes calldata data) external returns (uint256) {
        emit DepositCalled(assets, data);
        return assets;
    }

    function withdraw(uint256 assets, bytes calldata data) external returns (uint256) {
        emit WithdrawCalled(assets, data);
        return assets;
    }

    function harvest(bytes calldata data) external returns (uint256) {
        emit HarvestCalled(data);
        return 0;
    }
}

contract TestERC20 is Test {
    string public name;
    string public symbol;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function decimals() public pure returns (uint8) {
        return 18;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        emit Transfer(msg.sender, to, a);
        return true;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        emit Approval(msg.sender, s, a);
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        require(al >= a, "ALW");
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        emit Transfer(f, t, a);
        return true;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        emit Transfer(address(0), to, a);
    }

    function totalSupply() external view returns (uint256) {
        return 0;
    } // for rewards tests compatibility
}

contract SpokeYieldVaultTest is Test {
    SpokeYieldVault vault;
    TestERC20 asset;
    SuperchainERC20 lst;
    address gov = address(0xA11CE);
    address hub = address(0xB0B);
    address rebal = address(0xBEEF);
    MockAdapterRegistry reg;

    function setUp() public {
        vm.startPrank(gov);
        asset = new TestERC20("ASSET", "AST");
        lst = new SuperchainERC20("LST", "LST");
        lst.grantMinter(gov);
        reg = new MockAdapterRegistry();
        vault = new SpokeYieldVault();
        vault.initialize(IERC20(address(asset)), "Vault", "vAST", hub, gov, rebal, address(reg), gov, 0, address(lst));
        lst.grantMinter(address(vault));
        vm.stopPrank();
        asset.mint(address(this), 1000 ether);
        asset.approve(address(vault), type(uint256).max);
    }

    function testDepositMintsLST() public {
        uint256 beforeBal = lst.balanceOf(address(this));
        vault.deposit(100 ether, address(this));
        assertEq(lst.balanceOf(address(this)) - beforeBal, 100 ether);
    }

    function testRedeemBurnsLST() public {
        vault.deposit(50 ether, address(this));
        uint256 beforeBal = lst.balanceOf(address(this));
        vault.redeem(50 ether, address(this), address(this));
        assertEq(beforeBal - lst.balanceOf(address(this)), 50 ether);
    }

    function testWithdrawalBufferSetAndServeLocal() public {
        vm.prank(gov);
        vault.setWithdrawalBufferBps(10_000);
        vault.deposit(100 ether, address(this));
        // hub-only function, grant role (capture role before prank to ensure prank applies to grantRole call)
        bytes32 hubRole = vault.HUB_ROLE();
        vm.prank(gov);
        vault.grantRole(hubRole, hub);
        vm.prank(hub);
        vault.requestRemoteLiquidity(address(this), 20 ether);
        // asset transferred locally
        assertEq(asset.balanceOf(address(this)), 920 ether); // 1000 - 100 + 20
    }

    function testRequestRemoteLiquidityNoEmitWhenNotServed() public {
        // set small buffer and no balance; disable bridge so insufficient buffer reverts
        vm.prank(gov);
        vault.setWithdrawalBufferBps(0);
        vm.prank(gov);
        vault.setFlags(true, true, false);
        // grant hub role
        bytes32 hubRole = vault.HUB_ROLE();
        vm.prank(gov);
        vault.grantRole(hubRole, hub);
        vm.prank(hub);
        vm.expectRevert(abi.encodeWithSignature("InsufficientBuffer()"));
        vault.requestRemoteLiquidity(address(this), 1 ether);
    }

    function testOnRemoteCreditNonceIdempotent() public {
        // grant hub role
        bytes32 hubRole = vault.HUB_ROLE();
        vm.prank(gov);
        vault.grantRole(hubRole, hub);
        // enable bridge
        vm.prank(gov);
        vault.setFlags(true, true, true);
        // perform once
        vm.prank(hub);
        vault.onRemoteCredit(address(this), 1, 1, 1, bytes32("aid"));
        // replay should revert
        vm.prank(hub);
        vm.expectRevert();
        vault.onRemoteCredit(address(this), 1, 1, 1, bytes32("aid"));
    }

    function testSetFlagsAndDepositRevertsWhenDisabled() public {
        vm.prank(gov);
        vault.setFlags(false, false, true);
        vm.expectRevert(abi.encodeWithSignature("DepositsDisabled()"));
        vault.deposit(1, address(this));
    }

    function testBridgeDisabledRevertsOnRemote() public {
        // disable bridge
        vm.prank(gov);
        vault.setFlags(true, true, false);
        // onRemoteCredit and requestRemoteLiquidity require HUB_ROLE
        bytes32 hubRole = vault.HUB_ROLE();
        vm.prank(gov);
        vault.grantRole(hubRole, hub);
        vm.prank(hub);
        vm.expectRevert(abi.encodeWithSignature("BridgeDisabled()"));
        vault.onRemoteCredit(address(this), 1, 1, 1, bytes32(0));
        vm.prank(hub);
        vm.expectRevert(abi.encodeWithSignature("InsufficientBuffer()"));
        vault.requestRemoteLiquidity(address(this), 1);
    }

    function testPayOutBorrowAndOnSeizeSharesFlow() public {
        // grant controller role
        bytes32 ctrl = vault.CONTROLLER_ROLE();
        vm.prank(gov);
        vault.grantRole(ctrl, address(this));
        // deposit to get shares and LST, then seize part
        vault.deposit(40 ether, address(this));
        // pay out borrow from vault balance (uses deposited funds)
        uint256 before = asset.balanceOf(address(this));
        vault.payOutBorrow(address(this), address(asset), 10 ether);
        assertEq(asset.balanceOf(address(this)) - before, 10 ether);
        uint256 lstBefore = lst.balanceOf(address(this));
        uint256 sharesBefore = vault.balanceOf(address(this));
        address to = address(0x999);
        vault.onSeizeShares(address(this), 10 ether, to);
        assertEq(lstBefore - lst.balanceOf(address(this)), 10 ether);
        assertEq(vault.balanceOf(to), 10 ether);
        assertEq(vault.balanceOf(address(this)), sharesBefore - 10 ether);
    }

    function testAllocateDeallocateHarvestAndCaps() public {
        // ensure the vault holds assets to allocate (allocation now transfers from vault to adapter)
        vault.deposit(10 ether, address(this));
        // Allowed registry path with large cap
        MockAdapterTarget adapter = new MockAdapterTarget();
        vm.prank(rebal);
        vault.allocateToAdapter(address(adapter), 5 ether, bytes(""));
        vm.prank(rebal);
        vault.deallocateFromAdapter(address(adapter), 2 ether, bytes(""));
        vm.prank(rebal);
        vault.harvestAdapter(address(adapter), bytes(""));

        // Not allowed adapter registry
        MockAdapterRegistryVar reg2 = new MockAdapterRegistryVar(false, type(uint256).max);
        SpokeYieldVault vault2 = new SpokeYieldVault();
        vm.prank(gov);
        vault2.initialize(
            IERC20(address(asset)), "Vault2", "vAST2", hub, gov, rebal, address(reg2), gov, 0, address(lst)
        );
        vm.expectRevert(abi.encodeWithSignature("NotAllowedAdapter()"));
        vm.prank(rebal);
        vault2.allocateToAdapter(address(adapter), 1 ether, bytes(""));

        // Cap exceeded path
        MockAdapterRegistryVar reg3 = new MockAdapterRegistryVar(true, 1 ether);
        SpokeYieldVault vault3 = new SpokeYieldVault();
        vm.prank(gov);
        vault3.initialize(
            IERC20(address(asset)), "Vault3", "vAST3", hub, gov, rebal, address(reg3), gov, 0, address(lst)
        );
        vm.expectRevert(abi.encodeWithSignature("CapExceeded()"));
        vm.prank(rebal);
        vault3.allocateToAdapter(address(adapter), 2 ether, bytes(""));
    }
}
