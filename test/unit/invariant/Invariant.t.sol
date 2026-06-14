// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test, console } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import { TSwapPool } from "../../../src/TSwapPool.sol";
import { PoolFactory } from "../../../src/PoolFactory.sol";
import { Handler } from "./Handler.t.sol";

contract InvariantTest is StdInvariant, Test {
    ERC20Mock poolToken;
    ERC20Mock weth;

    PoolFactory factory;
    TSwapPool pool; //poolToken/weth

    int256 constant STARTING_TOKEN_BALANCE=1000e18; // STARTING POOL TOKEN BALANCE
    int256 constant STARTING_WETH_BALANCE=500e18; // STARTING WETH BALANCE

    Handler handler;

    function setUp() public {
        poolToken = new ERC20Mock();
        weth = new ERC20Mock();

        factory = new PoolFactory(address(weth));
        pool =TSwapPool(factory.createPool(address(poolToken)));

        poolToken.mint(address(this), uint256(STARTING_TOKEN_BALANCE));
        weth.mint(address(this), uint256(STARTING_WETH_BALANCE));

        poolToken.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);

        pool.deposit(uint256(STARTING_WETH_BALANCE), uint256(STARTING_TOKEN_BALANCE), uint256(STARTING_TOKEN_BALANCE), uint64(block.timestamp));

        handler = new Handler(pool);
        
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = handler.swapPoolTokenForWethBasedOnOutputWeth.selector;
        targetSelector(
            FuzzSelector({addr:address(handler), selectors:selectors})
            );
        targetContract(address(handler));
    }
    function invariant_contstantProductFormulaStaysTheSameForToken() public {
        assertEq(handler.actualDeltaTokenBalance(), handler.expectedDeltaTokenBalance());
    }
    function invariant_contstantProductFormulaStaysTheSameForWeth() public {
        assertEq(handler.actualDeltaWethBalance(), handler.expectedDeltaWethBalance());
    }
}