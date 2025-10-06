// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockAggregator {
    int256 public answer;
    uint256 public updatedAt;

    constructor(int256 _answer, uint256 _updatedAt) {
        answer = _answer;
        updatedAt = _updatedAt;
    }

    function setAnswer(int256 _answer) external { answer = _answer; }
    function setUpdatedAt(uint256 _updatedAt) external { updatedAt = _updatedAt; }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, answer, updatedAt, updatedAt, 0);
    }
}
