// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";

import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";

contract DecentralizedStableCoinTest is Test {
    DecentralizedStableCoin dsc;

    function setUp() public {
        dsc = new DecentralizedStableCoin();
    }

    function test_name() public view {
        assertEq(dsc.name(), "Decentralized Stable Coin");
    }

    function test_symbol() public view {
        assertEq(dsc.symbol(), "DSC");
    }

    function test_mint() public {
        dsc.mint(address(this), 100);
        assertEq(dsc.balanceOf(address(this)), 100);
    }

    function test_mint_reverts_when_to_is_zeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(DecentralizedStableCoin.DecentralizedStableCoin__ZeroAddress.selector));
        dsc.mint(address(0), 100);
    }

    function test_mint_reverts_when_amount_is_zero() public {
        vm.expectRevert(
            abi.encodeWithSelector(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector)
        );
        dsc.mint(address(this), 0);
    }

    function test_burn() public {
        dsc.mint(address(this), 100);
        dsc.burn(50);
        assertEq(dsc.balanceOf(address(this)), 50);
    }

    function tests_burn_reverts_when_amount_is_zero() public {
        vm.expectRevert(
            abi.encodeWithSelector(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector)
        );
        dsc.burn(0);
    }

    function test_burn_reverts_when_amount_exceeds_balance() public {
        vm.expectRevert(
            abi.encodeWithSelector(DecentralizedStableCoin.DecentralizedStableCoin__BurnAmountExceedsBalance.selector)
        );
        dsc.burn(100);
    }
}
