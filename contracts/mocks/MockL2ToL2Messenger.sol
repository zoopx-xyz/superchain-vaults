// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockL2ToL2Messenger
/// @notice Queue-based mock with per-(src→dst) delay and duplicate/out-of-order toggles.
contract MockL2ToL2Messenger {
    struct Msg {
        uint256 srcChainId;
        address src;
        uint256 dstChainId;
        address dst;
        bytes data;
        uint256 availableBlock; // block after which delivery allowed
    }

    mapping(uint256 => mapping(uint256 => uint256)) public delayBlocks; // src=>dst=>delay
    Msg[] public queue;
    bool public allowDuplicates;
    bool public allowOutOfOrder;

    event Enqueued(
        uint256 indexed srcChainId, address indexed src, uint256 indexed dstChainId, address dst, uint256 availableBlock
    );
    event Delivered(address indexed dst, bytes data);

    function setDelay(uint256 srcChainId, uint256 dstChainId, uint256 blocksDelay) external {
        delayBlocks[srcChainId][dstChainId] = blocksDelay;
    }

    function setToggles(bool _dupes, bool _ooo) external {
        allowDuplicates = _dupes;
        allowOutOfOrder = _ooo;
    }

    function sendMessage(address target, bytes calldata message) external {
        uint256 srcChainId = block.chainid; // treat as source
        // dstChainId to be provided by test harness; encode in message prefix if needed.
        // For simplicity, we store 0 for dstChainId here; tests can set delay on (src->0) if desired.
        uint256 dstChainId = 0;
        uint256 avail = block.number + delayBlocks[srcChainId][dstChainId];
        queue.push(
            Msg({
                srcChainId: srcChainId,
                src: msg.sender,
                dstChainId: dstChainId,
                dst: target,
                data: message,
                availableBlock: avail
            })
        );
        emit Enqueued(srcChainId, msg.sender, dstChainId, target, avail);
    }

    function size() external view returns (uint256) {
        return queue.length;
    }

    function deliverNext() public {
        require(queue.length > 0, "EMPTY");
        uint256 idx = 0;
        if (allowOutOfOrder) {
            // find any deliverable message
            for (uint256 i = 0; i < queue.length; i++) {
                if (queue[i].availableBlock <= block.number) {
                    idx = i;
                    break;
                }
            }
        }
        Msg memory m = queue[idx];
        require(m.availableBlock <= block.number, "NOT_READY");
        // pop idx
        if (idx != queue.length - 1) {
            queue[idx] = queue[queue.length - 1];
        }
        queue.pop();
        (bool ok,) = m.dst.call(m.data);
        require(ok, "DELIVER_FAIL");
        emit Delivered(m.dst, m.data);
        if (allowDuplicates) {
            // re-enqueue duplicate for adversarial tests
            queue.push(m);
        }
    }

    function deliverAll() external {
        uint256 guard = 0;
        while (queue.length > 0 && guard < 256) {
            // prevent infinite loops in tests
            if (queue[0].availableBlock > block.number) break;
            deliverNext();
            guard++;
        }
    }
}
