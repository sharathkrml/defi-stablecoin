// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

/**
 * @title Decentralized stable coin engine
 * @author sharathkrml
 *
 * System is deigned to be as minimal as possible
 * have the tokens maintain a 1 token = $1 peg
 * Our DSC system should be always overcollateralized
 * At no point, value of collateral should be <= value of DSC
 * his contract is Core of DSC system, it handles all logic for minting & redeeming DSC as well as depositing & withdrawing collateral
 */
contract DSCEngine is ReentrancyGuard {
    ////////////////////
    //    Errors  //
    ////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__MintFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);

    /////////////////////////
    //    State variables  //
    /////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTHFACTOR = 1;

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeeds
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private i_dsc;

    //////////////////
    //    Events   //
    /////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed user, address indexed token, uint256 indexed amount);
    ////////////////////
    //    Modifiers  //
    ////////////////////

    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _token) {
        // check if token is allowed
        if (s_priceFeeds[_token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    ////////////////////
    //    Functions   //
    ////////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////////////
    //    External Functions   //
    /////////////////////////////
    /**
     * @param tokenCollateralAddress: address of token to be deposited as collateral
     * @param amountCollateral: amount of token to be deposited as collateral
     * @param amountDscToMint: amount of dsc to mint
     * @notice this function deposits collateral and mints DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @param tokenCollateralAddress: address of token to be deposited as collateral
     * @param amountCollateral: amount of token to be deposited as collateral
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }
    /**
     * THis function burns DSC and redeems underlying collateral in 1 transaction
     * @param collateralAddress The collateral address to redeem
     * @param amountCollateral the amount of collateral to redeem
     * @param amoundDscToBurn the amount of DSC to burn
     */

    function redeemCollatoralForDsc(address collateralAddress, uint256 amountCollateral, uint256 amoundDscToBurn)
        external
    {
        burnDsc(amoundDscToBurn);
        redeemCollatoral(collateralAddress, amountCollateral);
        // redeem collateral already checks for health factor
    }

    // In order to redeem collateral
    // health factor must be above 1 AFTER collateral pulled
    function redeemCollatoral(address collateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(collateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][collateralAddress] -= amountCollateral;
        emit CollateralRedeemed(msg.sender, collateralAddress, amountCollateral);
        // use transfer since we are sending to user
        bool success = IERC20(collateralAddress).transfer(msg.sender, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     *
     * @param amountDscToMint : amount of Decentralized Stable Coin to mint
     * @notice they must have more collateral value than the minimum threshhold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        //  1. check if collateral value > DSC value. Price feeds, value
        // someone deposits $300 but wants to mint only $200
        s_DSCMinted[msg.sender] += amountDscToMint;
        // if they minted too much (eg: $150 DSC minted but $100 collateral deposited)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        s_DSCMinted[msg.sender] -= amount;
        bool success = i_dsc.transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amount);
        _revertIfHealthFactorIsBroken(msg.sender); // this won't be needed mostly
    }

    function liquidate() external {}

    function getHealthFactor() external view {}

    ///////////////////////////////////////
    //    Private & Internal View Functions   //
    ///////////////////////////////////////
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        uint256 totalCollateralValue = getAccountCollateralValue(user);
        return (totalDscMinted, totalCollateralValue);
    }
    /**
     * Return how close to liquidation the user is
     * If user goes below 1, they can get liquidated
     * @param user : address of user
     */

    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral value
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold =
            totalCollateralValueInUsd * LIQUIDATION_THRESHHOLD / LIQUIDATION_PRECISION;

        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) private view {
        // check if collateral value > DSC value. (HEALTH FACTOR)
        uint256 healthFactor = _healthFactor(user);
        // someone deposits $300 but wants to mint only $200
        if (healthFactor < MIN_HEALTHFACTOR) {
            revert DSCEngine__BreaksHealthFactor(healthFactor);
        }
    }

    ///////////////////////////////////////
    //    View & Pure functions   //
    ///////////////////////////////////////
    function getAccountCollateralValue(address user) public view returns (uint256) {
        uint256 totalCollateralValueInUsd = 0;
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // price is in 8 decimals, so we multiply by 1e10
        // amount is in 18 decimals
        // we divide by 1e18
        return (uint256(price) * ADDITIONAL_FEED_PRECISION) * amount / PRECISION;
    }
}
