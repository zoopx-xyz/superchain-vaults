// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SpokeYieldVault} from "contracts/spoke/SpokeYieldVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SuperchainERC20} from "contracts/tokens/SuperchainERC20.sol";
import {AdapterRegistry} from "contracts/strategy/AdapterRegistry.sol";

// Minimal ERC20 implementation for underlying asset compatible with ERC4626
contract ERC20MiniFull {
    string public name = "Asset";
    string public symbol = "AST";
    uint8 public immutable decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= value, "ALLOW");
        unchecked { allowance[from][msg.sender] = a - value; }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(balanceOf[from] >= value, "BAL");
        unchecked { balanceOf[from] -= value; balanceOf[to] += value; }
        emit Transfer(from, to, value);
    }

    function mint(address to, uint256 value) external {
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    function burn(address from, uint256 value) external {
        require(balanceOf[from] >= value, "BAL");
        unchecked { balanceOf[from] -= value; totalSupply -= value; }
        emit Transfer(from, address(0), value);
    }
}

// Echidna harness for SpokeYieldVault
contract Echidna_SpokeYieldVaultProps {
    SpokeYieldVault public vault;
    ERC20MiniFull public asset;
    SuperchainERC20 public lst;
    AdapterRegistry public registry;

    constructor() {
        asset = new ERC20MiniFull();
        lst = new SuperchainERC20("LST", "LST");
        registry = new AdapterRegistry();
        registry.initialize(address(this));

        vault = new SpokeYieldVault();
        vault.initialize(
            IERC20(address(asset)),
            "Spoke Vault",
            "SV",
            address(this), // hub
            address(this), // governor
            address(this), // rebalancer
            address(registry),
            address(this), // feeRecipient
            0, // performanceFeeBps
            address(lst)
        );
        // Allow vault to mint/burn LST
        lst.grantMinter(address(vault));
    }

    // Helpers for Echidna to move tokens/approve
    function gift(uint256 amt) public {
        uint256 a = amt % (1_000_000 ether);
        asset.mint(msg.sender, a);
        // approve large allowance for vault
        // use max to keep approvals sticky
        asset.approve(address(vault), type(uint256).max);
    }

    function deposit(uint256 amt) public {
        uint256 a = amt % (100_000 ether);
        try vault.deposit(a, msg.sender) { } catch { }
    }

    function redeem(uint256 shares) public {
        uint256 s = shares % (100_000 ether);
        try vault.redeem(s, msg.sender, msg.sender) { } catch { }
    }

    // Governor wrappers
    function setFlags(bool d, bool b, bool br) public {
        // governor-only; harness is governor
        try vault.setFlags(d, b, br) { } catch { }
    }

    function setWithdrawalBufferBps(uint16 bps) public {
        try vault.setWithdrawalBufferBps(bps) { } catch { }
    }

    function setEpochOutflowConfig(uint16 capBps, uint64 len) public {
        try vault.setEpochOutflowConfig(capBps, len) { } catch { }
    }

    // Properties
    function echidna_buffer_bps_valid() public view returns (bool) {
        return vault.withdrawalBufferBps() <= 10_000;
    }

    function echidna_epoch_cap_bps_valid() public view returns (bool) {
        return vault.epochOutflowCapBps() <= 10_000;
    }

    function echidna_deposit_respects_flag() public returns (bool) {
        // disable deposits; attempt to deposit; expect no successful increase
        // snapshot supplies
        uint256 beforeShares = vault.balanceOf(address(this));
        try vault.setFlags(false, false, true) { } catch { }
        // try to deposit from harness
        try vault.deposit(1 ether, address(this)) { } catch { }
        // re-enable for future sequences
        try vault.setFlags(true, false, true) { } catch { }
        // if shares increased while deposits disabled, fail
        return vault.balanceOf(address(this)) <= beforeShares;
    }
}
