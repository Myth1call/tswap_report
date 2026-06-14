// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test, console } from "forge-std/Test.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { TSwapPool } from "../../../src/TSwapPool.sol";
import { PoolFactory } from "../../../src/PoolFactory.sol";

contract Handler is Test {

    TSwapPool pool;
    ERC20Mock poolToken;
    ERC20Mock weth;

    address liquidityProvider = makeAddr("liquidityProvider");
    address swaper = makeAddr("swaper");
    // ghost variables
    int256 startingWethBalance;
    int256 startingTokenBalance;

    int256 public expectedDeltaWethBalance;
    int256 public expectedDeltaTokenBalance;

    int256 public actualDeltaWethBalance;
    int256 public actualDeltaTokenBalance;

    constructor(TSwapPool _pool){
        pool = _pool;
        weth = ERC20Mock(pool.getWeth());
        poolToken = ERC20Mock(pool.getPoolToken());
    }

    
    function setUp(TSwapPool _pool) public {
        pool = _pool;
        weth = ERC20Mock(pool.getWeth());
        poolToken = ERC20Mock(pool.getPoolToken());
    }

    function swapPoolTokenForWethBasedOnOutputWeth(uint256 outputWeth)public{
        if (weth.balanceOf(address(pool)) <= pool.getMinimumWethDepositAmount()) {
            return;
        }
        outputWeth=bound(outputWeth, pool.getMinimumWethDepositAmount(), weth.balanceOf(address(pool)));
        if(outputWeth == weth.balanceOf(address(pool))){
            return;
        }
        uint256 poolTokenAmount = pool.getInputAmountBasedOnOutput(
            outputWeth,
            poolToken.balanceOf(address(pool)),
            weth.balanceOf(address(pool))
            );
        // if(poolTokenAmount>type(uint64).max){
        //     return;
        // }

        startingWethBalance = int256(weth.balanceOf(address(pool)));
        startingTokenBalance = int256(poolToken.balanceOf(address(pool)));
        expectedDeltaWethBalance = int256(-1)*int256(outputWeth);
        // expectedDeltaTokenBalance = int256(pool.getPoolTokensToDepositBasedOnWeth(poolTokenAmount));
        expectedDeltaTokenBalance = int256(poolTokenAmount);
        if(poolToken.balanceOf(swaper)<poolTokenAmount){
            poolToken.mint(swaper, poolTokenAmount-poolToken.balanceOf(swaper)+1);
        }
        vm.startPrank(swaper);
        poolToken.approve(address(pool), poolTokenAmount);
        pool.swapExactOutput(
            poolToken,
            weth,
            outputWeth,
            uint64(block.timestamp));
        vm.stopPrank();
        uint256 endingY = weth.balanceOf(address(pool));
        uint256 endingX = poolToken.balanceOf(address(pool));
        actualDeltaWethBalance = int256(endingY) - int256(startingWethBalance);
        actualDeltaTokenBalance = int256(endingX) - int256(startingTokenBalance);
    }

    function deposit(uint256 wethAmount) public {
        uint256 minWethAmount=pool.getMinimumWethDepositAmount();
        wethAmount=bound(wethAmount, minWethAmount, 200e18);
        startingWethBalance = int256(weth.balanceOf(address(pool)));
        startingTokenBalance = int256(poolToken.balanceOf(address(pool)));
        expectedDeltaWethBalance =int256(wethAmount);
        expectedDeltaTokenBalance = int256(pool.getPoolTokensToDepositBasedOnWeth(wethAmount));

        vm.startPrank(liquidityProvider);
        weth.mint(liquidityProvider, wethAmount);
        poolToken.mint(liquidityProvider, uint256(expectedDeltaTokenBalance));
        weth.approve(address(pool), wethAmount);
        poolToken.approve(address(pool), uint256(expectedDeltaTokenBalance));
        pool.deposit(wethAmount, 0, uint256(expectedDeltaTokenBalance), uint64(block.timestamp));
        vm.stopPrank();

        uint256 endingY = weth.balanceOf(address(pool));
        uint256 endingX = poolToken.balanceOf(address(pool));

        actualDeltaWethBalance = int256(endingY) - int256(startingWethBalance);
        actualDeltaTokenBalance = int256(endingX) - int256(startingTokenBalance);
    }
}