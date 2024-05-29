// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUSDPriceFeed;
    address btcUSDPriceFeed;
    address weth;
    address wbtc;
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    address public user = makeAddr("user");
    uint256 public constant STARTING_ERC20_BALANCE = 100 ether;
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant AMOUNT_DSC_TO_MINT = 100 ether;

    address public liquidator = makeAddr("liquidator");
    uint256 public constant COLLATERAL_TO_COVER = 100 ether;

    modifier depositedCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier mintedDSC() {
        vm.startPrank(user);
        dsce.mintDSC(AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
        _;
    }

    modifier preparedLiquidator() {
        ERC20Mock(weth).mint(liquidator, COLLATERAL_TO_COVER);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dsce), COLLATERAL_TO_COVER);
        dsce.depositCollateralAndMintDSC(weth, COLLATERAL_TO_COVER, AMOUNT_DSC_TO_MINT);
        dsc.approve(address(dsce), AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
        _;
    }

    modifier liquidated() {
        int256 ethUSDUpdatedPrice = 15e8; // 1 ETH = $15
        MockV3Aggregator(ethUSDPriceFeed).updateAnswer(ethUSDUpdatedPrice);

        vm.startPrank(liquidator);
        dsce.liquidate(weth, user, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
        _;
    }

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUSDPriceFeed, btcUSDPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(user, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(user, STARTING_ERC20_BALANCE);
    }

    ///////////////////////////////////////////////
    // Constructor Tests
    ///////////////////////////////////////////////

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUSDPriceFeed);
        priceFeedAddresses.push(btcUSDPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAdressesAndPriceFeedsMustHaveSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ///////////////////////////////////////////////
    // Price Tests
    ///////////////////////////////////////////////
    function testGetUSDValue() public view {
        uint256 amount = 20e18;
        uint256 expectedUSD = 60000e18;
        assertEq(dsce.getUSDValue(weth, amount), expectedUSD);
    }

    function testGetTokenAmountFromUSD() public view {
        uint256 usdAmount = 90 ether;
        uint256 expectedAmount = 0.03 ether;
        assertEq(dsce.getTokenAmountFromUSD(weth, usdAmount), expectedAmount);
    }

    // // Test failing mintDSC due to price feed failure
    // function testMintDSCPriceFeedFails() public {
    //     uint256 amountDeposit = 1 ether;
    //     uint256 amountMint = 100e18;

    //     ERC20Mock(weth).mint(address(this), amountDeposit);
    //     ERC20Mock(weth).approve(address(dscEngine), amountDeposit);

    //     // Mock failing price feed call
    //     bytes memory priceFeedData = abi.encode(0); // Mock empty price data
    //     vm.mockCall(
    //         address(dscEngine.getPriceFeed()),
    //         abi.encodeWithSelector(dscEngine.getPriceFeed.getPrice.selector),
    //         priceFeedData
    //     );

    //     vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__PriceFeedFailed.selector));
    //     dscEngine.mintDSC(amountMint);
    // }

    ///////////////////////////////////////////////
    // Deposit Collateral Tests
    ///////////////////////////////////////////////
    function testRevertsIfCollateralZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testDepositNotAllowedToken() public {
        ERC20Mock mockToken = new ERC20Mock("MockToken", "MTK", user, STARTING_ERC20_BALANCE);
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(mockToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = dsce.getAccountInformation(user);
        uint256 expectedTotalDSCMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUSD(weth, collateralValueInUSD);
        assertEq(totalDSCMinted, expectedTotalDSCMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testDepositCollateralEmitsEvent() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectEmit(true, true, false, false);
        emit DSCEngine.CollateralDeposited(user, weth, AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testMultipleTokens() public {
        uint256 wethCollateral = 10 ether;
        uint256 wbtcCollateral = 20 ether;

        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), wethCollateral);
        ERC20Mock(wbtc).approve(address(dsce), wbtcCollateral);
        dsce.depositCollateral(weth, wethCollateral);
        dsce.depositCollateral(wbtc, wbtcCollateral);
        assertEq(dsce.getCollateralBalanceOfUser(user, weth), wethCollateral);
        assertEq(dsce.getCollateralBalanceOfUser(user, wbtc), wbtcCollateral);
        vm.stopPrank();
    }

    // Test depositing collateral with different allowances
    function testDepositCollateralWithAllowance() public {
        uint256 amountDeposit = 1 ether;
        uint256 lowAllowance = 0.5 ether;

        vm.startPrank(user);
        ERC20Mock(weth).mint(address(this), amountDeposit);

        // Approve less than deposit amount
        ERC20Mock(weth).approve(address(dsce), lowAllowance);
        vm.expectRevert();
        dsce.depositCollateral(weth, amountDeposit);

        // Approve full deposit amount
        ERC20Mock(weth).approve(address(dsce), amountDeposit);
        dsce.depositCollateral(weth, amountDeposit);

        vm.stopPrank();

        // Assert collateral is deposited
        assertEq(dsce.getCollateralBalanceOfUser(user, weth), amountDeposit);
    }

    ///////////////////////////////////////////////
    // Minting Tests
    ///////////////////////////////////////////////

    function testDepositCollateralAndMintDSC() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();

        // Assert collateral is deposited
        assertEq(dsce.getCollateralBalanceOfUser(user, weth), AMOUNT_COLLATERAL);

        // Assert user minted the expected amount of DSC
        assertEq(dsc.balanceOf(user), AMOUNT_DSC_TO_MINT);
    }

    function testMintDSC() public depositedCollateral {
        vm.prank(user);
        dsce.mintDSC(AMOUNT_DSC_TO_MINT);

        assertEq(dsc.balanceOf(user), AMOUNT_DSC_TO_MINT, "DSC mint amount incorrect");
    }

    function testMintDSCFailsDueToLowHealthFactor() public depositedCollateral {
        uint256 amountMint = AMOUNT_COLLATERAL * 1e4;
        vm.startPrank(user);
        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(amountMint, dsce.getUSDValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.mintDSC(amountMint);
        vm.stopPrank();
    }

    // Test failing to mint DSC due to DecentralizedStableCoin mint failure
    function testMintDSCFails() public depositedCollateral {
        vm.startPrank(user);
        // Mock failing mint in DecentralizedStableCoin
        vm.mockCall(
            address(dsc), abi.encodeWithSelector(dsc.mint.selector, user, AMOUNT_DSC_TO_MINT), abi.encode(false)
        );

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        dsce.mintDSC(AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
    }

    // Test minting zero DSC
    function testMintZeroDSC() public depositedCollateral {
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dsce.mintDSC(0);
        vm.stopPrank();

        // Assert no change in minted DSC
        assertEq(dsc.balanceOf(user), 0);
    }

    ///////////////////////////////////////////////
    // Redeem Collateral Tests
    ///////////////////////////////////////////////
    function testRevertsWithZeroRedeemCollateral() public depositedCollateral {
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithZeroRedeemCollateralForDSC() public depositedCollateral {
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dsce.redeemCollateralForDSC(weth, 0, 0);
        vm.stopPrank();
    }

    function testUserBalanceAfterRedeemCollateral() public depositedCollateral {
        uint256 amountRedeem = 1 ether;

        vm.startPrank(user);
        dsce.redeemCollateral(weth, amountRedeem);

        // Assert that the collateral was redeemed
        assertEq(ERC20Mock(weth).balanceOf(user), STARTING_ERC20_BALANCE - AMOUNT_COLLATERAL + amountRedeem);
        vm.stopPrank();
    }

    function testCollateralDepositedAfterRedeemCollateral() public depositedCollateral {
        uint256 amountRedeem = 1 ether;

        vm.startPrank(user);
        dsce.redeemCollateral(weth, amountRedeem);
        vm.stopPrank();

        // Check collateral balance decreased
        assertEq(dsce.getCollateralBalanceOfUser(user, weth), AMOUNT_COLLATERAL - amountRedeem);
    }

    function testRedeemCollateralAndBurnDSC() public depositedCollateral mintedDSC {
        vm.startPrank(user);
        dsc.approve(address(dsce), AMOUNT_DSC_TO_MINT);
        dsce.redeemCollateralForDSC(weth, AMOUNT_COLLATERAL, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
        assertEq(dsc.balanceOf(user), 0);
    }

    function testRevertsRedeemMoreCollateralThanDeposited() public depositedCollateral {
        vm.startPrank(user);
        vm.expectRevert();
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL + 1 ether);
        vm.stopPrank();
    }

    function testRedeemCollateralEmitsEvent() public depositedCollateral {
        vm.startPrank(user);
        vm.expectEmit(true, true, true, false);
        emit DSCEngine.CollateralRedeemed(user, user, weth, AMOUNT_COLLATERAL);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsRedeemCollateralBreaksHealthFactor() public depositedCollateral mintedDSC {
        vm.startPrank(user);
        uint256 expectedHealthFactor = 0;
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    // Test failing to redeem collateral due to transfer failure
    function testRedeemCollateralFails() public depositedCollateral mintedDSC {
        uint256 amountRedeem = 0.5 ether;

        vm.startPrank(user);
        // Mock failing transfer in ERC20
        vm.mockCall(
            weth, abi.encodeWithSelector(ERC20Mock(weth).transfer.selector, user, amountRedeem), abi.encode(false)
        );

        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        dsce.redeemCollateral(weth, amountRedeem);
        vm.stopPrank();
    }

    ///////////////////////////////////////////////
    // Burn DSC Tests
    ///////////////////////////////////////////////
    function testBurnDSC() public depositedCollateral {
        vm.startPrank(user);
        dsce.mintDSC(50 ether);
        dsc.approve(address(dsce), 50 ether);
        dsce.burnDSC(25 ether);
        assertEq(dsc.balanceOf(user), 25 ether);
        vm.stopPrank();
    }

    // Test burning more DSC than user has minted
    function testBurnMoreThanMinted() public {
        vm.prank(user);
        vm.expectRevert();
        dsce.burnDSC(1);
    }

    function testRevertsWithZeroBurnDSC() public depositedCollateral mintedDSC {
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dsce.burnDSC(0);
        vm.stopPrank();
    }

    ///////////////////////////////////////////////
    // Health Factor Tests
    ///////////////////////////////////////////////

    function testCalculateHealthFactor() public depositedCollateral mintedDSC {
        // Calculate health factor
        uint256 expectedHealthFactor = dsce.calculateHealthFactor(
            AMOUNT_DSC_TO_MINT, dsce.getUSDValue(weth, AMOUNT_COLLATERAL)
        );

        uint256 actualHealthFactor = dsce.getHealthFactor(user);

        assertEq(expectedHealthFactor, actualHealthFactor);
    }

    function testMinHealthFactor() public depositedCollateral mintedDSC {
        // Arrange: Set up necessary state, e.g. deposit collateral and mint DSC

        // Act: Calculate health factor
        uint256 healthFactor = dsce.getHealthFactor(user);

        // Assert: Check that health factor is calculated correctly
        assertGt(healthFactor, dsce.getMinHealthFactor(), "Health factor should be above the minimum");
    }

    ///////////////////////////////////////////////
    //  Liquidation Tests
    ///////////////////////////////////////////////

    // Test liquidation when user has enough health factor
    function testLiquidationHealthyUser() public depositedCollateral mintedDSC preparedLiquidator {
        vm.startPrank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorNotBroken.selector));
        dsce.liquidate(weth, user, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
    }

    function testUnauthorizedTokenLiquidationAttempt() public depositedCollateral mintedDSC preparedLiquidator {
        ERC20Mock mockToken = new ERC20Mock("MockToken", "MTK", liquidator, STARTING_ERC20_BALANCE);
        vm.startPrank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__NotAllowedToken.selector));
        dsce.liquidate(address(mockToken), user, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
    }

    function testLiquidationDoesntImproveHealthFactor() public depositedCollateral mintedDSC preparedLiquidator {
        int256 ethUSDUpdatedPrice = 10e8; // 1 ETH = $10
        MockV3Aggregator(ethUSDPriceFeed).updateAnswer(ethUSDUpdatedPrice);

        uint256 debtToCover = 10 ether;

        vm.startPrank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorNotImproved.selector));
        dsce.liquidate(weth, user, debtToCover);
        vm.stopPrank();
    }

    function testLiquidationPayoutIsCorrect() public depositedCollateral mintedDSC preparedLiquidator liquidated {
        uint256 liquidatorBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = dsce.getTokenAmountFromUSD(weth, AMOUNT_DSC_TO_MINT)
            + (dsce.getTokenAmountFromUSD(weth, AMOUNT_DSC_TO_MINT) / dsce.getLiquidationBonus());
        assertEq(liquidatorBalance, expectedWeth, "Liquidator should receive correct amount of ETH");
    }

    function testUserStillHasSomeEthAfterLiquidation()
        public
        depositedCollateral
        mintedDSC
        preparedLiquidator
        liquidated
    {
        uint256 amountLiquidated = dsce.getTokenAmountFromUSD(weth, AMOUNT_DSC_TO_MINT)
            + (dsce.getTokenAmountFromUSD(weth, AMOUNT_DSC_TO_MINT) / dsce.getLiquidationBonus());
        uint256 usdAmountLiquidated = dsce.getUSDValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUSD =
            dsce.getUSDValue(weth, AMOUNT_COLLATERAL) - usdAmountLiquidated;
        uint256 userCollateralValueInUSD = dsce.getAccountCollateralValue(user);
        assertEq(expectedUserCollateralValueInUSD, userCollateralValueInUSD, "User should have correct amount of ETH");
    }

    function testUserStillHasSomeEthAfterLiquidation2()
        public
        depositedCollateral
        mintedDSC
        preparedLiquidator
        liquidated
    {
        uint256 amountLiquidated = dsce.getTokenAmountFromUSD(weth, AMOUNT_DSC_TO_MINT)
            + (dsce.getTokenAmountFromUSD(weth, AMOUNT_DSC_TO_MINT) / dsce.getLiquidationBonus());
        uint256 expectedUserCollateralValue = AMOUNT_COLLATERAL - amountLiquidated;
        uint256 userCollateralValue = dsce.getCollateralBalanceOfUser(user, weth);
        assertEq(expectedUserCollateralValue, userCollateralValue, "User should have correct amount of ETH");
    }

    function testLiquidatorTakesOnUserDebt() public depositedCollateral mintedDSC preparedLiquidator liquidated {
        (uint256 liquidatorDSCMinted,) = dsce.getAccountInformation(liquidator);
        assertEq(liquidatorDSCMinted, AMOUNT_DSC_TO_MINT);
    }

    function testUserHasNoMoreDebt() public depositedCollateral mintedDSC preparedLiquidator liquidated {
        (uint256 userDSCMinted,) = dsce.getAccountInformation(user);
        assertEq(userDSCMinted, 0);
    }
}
