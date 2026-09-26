// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @title MockPriceOracle — demo/local price simulation (docs/14)
/// @notice Reproduce §5 drop scenarios via arbitrary price changes (setPrice). Interface and fail-safe match production.
contract MockPriceOracle is IPriceOracle {
    uint256 private _price; // 8 decimals
    address public owner;

    event PriceUpdated(uint256 oldPrice, uint256 newPrice);
    event OwnerTransferred(address indexed from, address indexed to);

    error NotOwner();
    error ZeroPrice();

    constructor(uint256 initialPrice8) {
        if (initialPrice8 == 0) revert ZeroPrice();
        _price = initialPrice8;
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function setPrice(uint256 price8) external onlyOwner {
        if (price8 == 0) revert ZeroPrice(); // fail-safe P1
        emit PriceUpdated(_price, price8);
        _price = price8;
    }

    function transferOwnership(address to) external onlyOwner {
        emit OwnerTransferred(owner, to);
        owner = to;
    }

    function btcPrice() external view returns (uint256) {
        return _price; // _price>0 guaranteed (constructor/setter)
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}
