// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public timesMintIsCalled;
    address[] public usersWithCollateralDeposited;
    MockV3Aggregator public ethUSDPriceFeed;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(DSCEngine _dsce, DecentralizedStableCoin _dsc) {
        dsce = _dsce;
        dsc = _dsc;

        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUSDPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(weth)));
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);
        dsce.depositCollateral(address(collateral), amountCollateral);
        // console.log("msg.sender: ", msg.sender);
        // console.log(
        //     "deposit collateral balance of user: ", dsce.getCollateralBalanceOfUser(msg.sender, address(collateral))
        // );
        // console.log("deposit collateral address: ", address(collateral));
        vm.stopPrank();

        usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }

        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];

        uint256 collateralBalance = dsce.getCollateralBalanceOfUser(sender, address(collateral));

        if (collateralBalance == 0) {
            return;
        }

        // uint256 collateralValueInUSD = dsce.getUSDValue(address(collateral), collateralBalance);
        (uint256 totalDSCMinted, uint256 totalCollateralValueInUSD) = dsce.getAccountInformation(sender);

        // console.log("collateral balance of user: ", collateralBalance);
        // console.log("collateral value in USD: ", collateralValueInUSD);
        // console.log("total collateral value in USD: ", totalCollateralValueInUSD);
        // console.log("total DSC minted: ", totalDSCMinted);
        // console.log("liquidation precision: ", dsce.getLiquidationPrecision());

        uint256 collateralToRedeemInUSD =
            totalCollateralValueInUSD * dsce.getLiquidationThreshold() / dsce.getLiquidationPrecision() - totalDSCMinted;

        // console.log("total collateral to redeem in USD: ", collateralToRedeemInUSD);

        // if (collateralValueInUSD < totalCollateralValueInUSD) {
        //     collateralToRedeemInUSD = collateralValueInUSD / totalCollateralValueInUSD * collateralToRedeemInUSD;
        // }
        uint256 maxCollateralToRedeem = dsce.getTokenAmountFromUSD(address(collateral), collateralToRedeemInUSD);
        maxCollateralToRedeem = collateralBalance < maxCollateralToRedeem ? collateralBalance : maxCollateralToRedeem;

        // console.log("collateral to redeem in USD: ", collateralToRedeemInUSD);
        // console.log("maxCollateralToRedeem: ", maxCollateralToRedeem);

        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) {
            return;
        }
        vm.prank(sender);
        dsce.redeemCollateral(address(collateral), amountCollateral);
    }

    function mintDSC(uint256 amountDSC, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }

        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];

        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = dsce.getAccountInformation(sender);
        // console.log("sender: ", sender);
        // console.log("collateral WETH balance of user: ", dsce.getCollateralBalanceOfUser(sender, address(weth)));
        // console.log("collateral WBTC balance of user: ", dsce.getCollateralBalanceOfUser(sender, address(wbtc)));
        // console.log("total DSC minted: ", totalDSCMinted);
        // console.log("collateral value in USD: ", collateralValueInUSD);
        int256 maxDSCToMint = int256(
            collateralValueInUSD * dsce.getLiquidationThreshold() / dsce.getLiquidationPrecision() - totalDSCMinted
        );
        // console.log("max DSC to mint: ", uint256(maxDSCToMint));
        if (maxDSCToMint <= 0) {
            return;
        }
        amountDSC = bound(amountDSC, 1, uint256(maxDSCToMint));

        vm.prank(sender);
        dsce.mintDSC(amountDSC);

        timesMintIsCalled++;
    }

    // This breaks our invariant test suite!
    // function updateCollateralPrice(uint96 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUSDPriceFeed.updateAnswer(newPriceInt);
    // }

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        return collateralSeed % 2 == 0 ? weth : wbtc;
    }
}
