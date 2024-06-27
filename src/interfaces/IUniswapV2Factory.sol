// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.13;

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}
