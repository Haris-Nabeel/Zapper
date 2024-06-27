// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {Zapper} from "../src/Zapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ZapperTest is Test {
    Zapper public zapper;
    IERC20 public USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 public WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address wethUsdcPair = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;

    function setUp() public {
        zapper = new Zapper();
    }

    function test_zapIn() public {
        uint amount = 10000000 * 10 ** 6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(zapper), amount);
        zapper.ZapIn(
            address(USDC),
            wethUsdcPair,
            amount,
            1,
            address(0),
            "0x",
            true
        );
    }
}
