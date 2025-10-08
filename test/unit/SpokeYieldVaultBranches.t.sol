// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SpokeYieldVault} from "contracts/spoke/SpokeYieldVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SuperchainERC20} from "contracts/tokens/SuperchainERC20.sol";

contract TokenM is Test {
    string public name = "AST"; string public symbol = "AST";
    mapping(address=>uint256) public balanceOf; mapping(address=>mapping(address=>uint256)) public allowance;
    event Transfer(address indexed from,address indexed to,uint256 value); event Approval(address indexed o,address indexed s,uint256 v);
    function decimals() external pure returns(uint8){return 18;}
    function mint(address to,uint256 a) external { balanceOf[to]+=a; emit Transfer(address(0),to,a);}    
    function transfer(address to,uint256 a) external returns(bool){ balanceOf[msg.sender]-=a; balanceOf[to]+=a; emit Transfer(msg.sender,to,a); return true;}
    function approve(address s,uint256 a) external returns(bool){ allowance[msg.sender][s]=a; emit Approval(msg.sender,s,a); return true; }
    function transferFrom(address f,address t,uint256 a) external returns(bool){ uint256 al=allowance[f][msg.sender]; require(al>=a,"ALW"); if(al!=type(uint256).max) allowance[f][msg.sender]=al-a; balanceOf[f]-=a; balanceOf[t]+=a; emit Transfer(f,t,a); return true; }
}

contract SpokeYieldVaultBranches is Test {
    SpokeYieldVault vault; TokenM asset; SuperchainERC20 lst; address gov=address(0xA11CE); address hub=address(0xB0B); address rebal=address(0xBEEF);

    function setUp() public {
        asset = new TokenM();
        // Deploy LST; admin may be this test contract or gov depending on sender semantics
        // We'll detect admin and use it explicitly for subsequent role grants.
        vm.prank(gov);
        lst = new SuperchainERC20("LST","LST");
        vault = new SpokeYieldVault();
        vault.initialize(IERC20(address(asset)), "Vault", "vAST", hub, gov, rebal, address(this), gov, 0, address(lst));
        // Determine who holds DEFAULT_ADMIN_ROLE on LST and use that account to grant MINTER_ROLEs
        address admin = lst.hasRole(lst.DEFAULT_ADMIN_ROLE(), gov) ? gov : address(this);
        vm.prank(admin);
        lst.grantMinter(gov);
        vm.prank(admin);
        lst.grantMinter(address(vault));
        asset.mint(address(this), 1_000 ether);
        asset.approve(address(vault), type(uint256).max);
        // grant HUB role (needs admin); use startPrank so HUB_ROLE() and grantRole() both run as gov
        vm.startPrank(gov);
        vault.grantRole(vault.HUB_ROLE(), hub);
        vm.stopPrank();
    }

    // AdapterRegistry methods used by vault
    function isAllowed(address) external pure returns (bool) { return true; }
    function capOf(address) external pure returns (uint256) { return type(uint256).max; }

    function _enqueue(uint256 shares) internal returns (uint256 claimId) {
        // Acquire shares by depositing to be able to compute target assets, though not strictly required for our branches
        vault.deposit(shares, address(this));
        claimId = vault.enqueueWithdraw(shares);
    }

    function testFulfillWithdrawBatchInvalidArrayReverts() public {
        uint256 c = _enqueue(10 ether);
        vm.prank(hub);
        vm.expectRevert(abi.encodeWithSignature("InvalidArray()"));
        uint256[] memory ids = new uint256[](1); ids[0]=c;
        uint256[] memory amts = new uint256[](0);
        vault.fulfillWithdrawBatch(ids, amts, bytes32("aid"));
    }

    function testFulfillWithdrawBatchDuplicateClaimReverts() public {
        uint256 c = _enqueue(5 ether);
        vm.prank(hub);
        vm.expectRevert(abi.encodeWithSignature("DuplicateClaim()"));
        uint256[] memory ids = new uint256[](2); ids[0]=c; ids[1]=c;
        uint256[] memory amts = new uint256[](2); amts[0]=0; amts[1]=0;
        vault.fulfillWithdrawBatch(ids, amts, bytes32("dup"));
    }

    function testFulfillWithdrawBatchHappyProcessesMultiple() public {
        // Arrange: deposit to have TVL and create two independent claims
        vault.deposit(20 ether, address(this));
        uint256 c1 = _enqueue(5 ether);
        uint256 c2 = _enqueue(7 ether);
        // Act: equal-length arrays, unique ids -> should not revert (covers non-revert branch on length check and no-duplicate path)
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amts = new uint256[](2);
        ids[0] = c1; ids[1] = c2;
        amts[0] = 1 ether; amts[1] = 2 ether;
        vm.prank(hub);
        vault.fulfillWithdrawBatch(ids, amts, bytes32("happy"));
        // Assert: both claims have some filled assets and remain active (partial fills)
        (address u1, uint128 s1, uint128 f1, bool a1,) = vault.claims(c1);
        (address u2, uint128 s2, uint128 f2, bool a2,) = vault.claims(c2);
        assertEq(u1, address(this));
        assertEq(u2, address(this));
        assertGt(uint256(f1), 0);
        assertGt(uint256(f2), 0);
        assertTrue(a1);
        assertTrue(a2);
    }

    function testFulfillWithdrawNonceUsedRevertsOnReplay() public {
        uint256 c = _enqueue(1 ether);
        bytes32 aid = bytes32("x");
        vm.prank(hub);
        vault.fulfillWithdraw(c, 0, aid);
        vm.prank(hub);
        vm.expectRevert(); // NonceUsed
        vault.fulfillWithdraw(c, 0, aid);
    }

    function testEpochOutflowCapEnforcedOnFulfill() public {
        vm.prank(gov); vault.setEpochOutflowConfig(100, 1 hours); // 1% per epoch
        vm.prank(gov); vault.setWithdrawalBufferBps(10_000);
        vault.deposit(100 ether, address(this));
        uint256 c = _enqueue(50 ether);
        // First fulfill within cap
        vm.prank(hub); vault.fulfillWithdraw(c, 1 ether, bytes32("a"));
        // Exceed remaining cap
        vm.prank(hub); vm.expectRevert(abi.encodeWithSignature("CapExceeded()"));
        vault.fulfillWithdraw(c, 100 ether, bytes32("b"));
    }

    function testEpochOutflowCapEnforcedOnRequestRemoteLiquidity() public {
        vm.prank(gov); vault.setEpochOutflowConfig(100, 1 hours); // 1%
        vm.prank(gov); vault.setWithdrawalBufferBps(10_000);
        vault.deposit(100 ether, address(this));
        // First call consumes exactly the cap (1% of 100 ether = 1 ether)
        vm.prank(hub); vault.requestRemoteLiquidity(address(this), 1 ether);
        // Second call with 1 wei should exceed remaining cap and revert while still being within local buffer
        vm.prank(hub); vm.expectRevert(abi.encodeWithSignature("CapExceeded()"));
        vault.requestRemoteLiquidity(address(this), 1);
    }

    function testEnqueueAggregateByActionIdAggregatesShares() public {
        // With epochLength set, two enqueues with same actionId in same epoch aggregate
        vm.prank(gov); vault.setEpochOutflowConfig(100, 1 hours);
        uint256 id1 = vault.enqueueWithdraw(10 ether, bytes32("aid"));
        uint256 id2 = vault.enqueueWithdraw(5 ether, bytes32("aid"));
        assertEq(id1, id2); // aggregated into same claim
    }

    function testFulfillInactiveClaimReverts() public {
        // Fully satisfy a claim and then attempt an extra fulfill; should revert INACTIVE
        vault.deposit(10 ether, address(this));
        uint256 cid = _enqueue(10 ether);
        uint256 target = vault.convertToAssets(10 ether);
        vm.prank(hub); vault.fulfillWithdraw(cid, target, bytes32("done"));
        vm.prank(hub); vm.expectRevert(bytes("INACTIVE"));
        vault.fulfillWithdraw(cid, 1, bytes32("again"));
    }

    function testRequestRemoteLiquidityBridgeEnabledNotServedNoRevert() public {
        // No local buffer and bridge enabled -> function is no-op and does not revert
        vm.prank(gov); vault.setWithdrawalBufferBps(0);
        vm.prank(gov); vault.setFlags(true, true, true);
        vm.startPrank(gov);
        vault.grantRole(vault.HUB_ROLE(), hub);
        vm.stopPrank();
        vm.prank(hub);
        vault.requestRemoteLiquidity(address(this), 1 ether);
        // balance should be unchanged because not served
        assertEq(asset.balanceOf(address(this)), 1000 ether);
    }

    function testConfigSettersRevertsOnInvalidInputs() public {
        vm.prank(gov); vm.expectRevert(bytes("BPS"));
        vault.setWithdrawalBufferBps(10001);
        vm.prank(gov); vm.expectRevert(bytes("LEN"));
        vault.setEpochOutflowConfig(100, 0);
    }
}
