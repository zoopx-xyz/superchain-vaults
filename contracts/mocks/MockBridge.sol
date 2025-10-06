// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockBridge
/// @notice Asynchronous token transfer with programmable delay & failure.
contract MockBridge {
    struct TransferReq { address token; address to; uint256 amount; uint256 availableBlock; bool fail; }
    TransferReq[] public queue;
    mapping(address => bool) public isToken;
    mapping(address => uint256) public delayBlocks; // token => delay

    event Enqueued(address indexed token, address indexed to, uint256 amount, uint256 availableBlock, bool fail);
    event Delivered(address indexed token, address indexed to, uint256 amount);

    function setToken(address token, bool ok) external { isToken[token] = ok; }
    function setDelay(address token, uint256 blocksDelay) external { delayBlocks[token] = blocksDelay; }

    function send(address token, address to, uint256 amount, bool fail) external {
        require(isToken[token], "TOKEN");
        uint256 avail = block.number + delayBlocks[token];
        queue.push(TransferReq({token: token, to: to, amount: amount, availableBlock: avail, fail: fail}));
        emit Enqueued(token, to, amount, avail, fail);
    }

    function deliverNext() public {
        require(queue.length > 0, "EMPTY");
        TransferReq memory t = queue[0];
        require(t.availableBlock <= block.number, "NOT_READY");
        // pop front
        if (queue.length > 1) {
            for (uint256 i = 0; i < queue.length - 1; i++) { queue[i] = queue[i+1]; }
        }
        queue.pop();
        if (!t.fail) {
            IERC20(t.token).transfer(t.to, t.amount);
            emit Delivered(t.token, t.to, t.amount);
        }
    }

    function deliverAll() external {
        uint256 guard = 0;
        while (queue.length > 0 && guard < 256) {
            if (queue[0].availableBlock > block.number) break;
            deliverNext();
            guard++;
        }
    }
}
