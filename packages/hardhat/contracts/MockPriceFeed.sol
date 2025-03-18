// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract MockPriceFeed {
    int256 public price;
    uint8 public decimals = 8;

    constructor(uint256 _initialPrice) {
        price = int256(_initialPrice);
    }

    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        return (0, price, 0, 0, 0);
    }

    function setPrice(uint256 _newPrice) external {
        price = int256(_newPrice);
    }
}
