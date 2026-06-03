// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ClanManager.sol";
import "../src/RoyaleEngine.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockGoodDollar
 * @dev A minimal ERC-20 token implementing ERC-677 transferAndCall for testing purposes.
 */
contract MockGoodDollar is ERC20 {
    constructor() ERC20("GoodDollar", "G$") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @dev Simulates ERC-677 transferAndCall behavior.
     */
    function transferAndCall(address to, uint256 value, bytes calldata data) external returns (bool) {
        _transfer(msg.sender, to, value);
        require(IERC677Receiver(to).onTokenTransfer(msg.sender, value, data), "ERC677: callback failed");
        return true;
    }
}

/**
 * @title GuildRoyaleTest
 * @dev Comprehensive Foundry test suite covering ClanManager and RoyaleEngine core logic.
 */
contract GuildRoyaleTest is Test {
    MockGoodDollar public gDollar;
    ClanManager public clanManager;
    RoyaleEngine public royaleEngine;

    // --- Test Actors ---
    address public owner = address(0xAA);
    address public platformTreasury = address(0xBB);
    address public backendOperator = address(0xCC);
    address public alice = address(0x01);
    address public bob = address(0x02);
    address public charlie = address(0x03);

    // --- Config Parameters ---
    uint256 public constant CREATION_FEE = 50 * 10**18; // 50 G$
    uint256 public constant STAKE_AMOUNT = 10 * 10**18; // 10 G$

    function setUp() public {
        // 1. Deploy Mock G$ Token
        vm.startPrank(owner);
        gDollar = new MockGoodDollar();

        // 2. Deploy Implementations and Initialize Proxies (Direct deployment configuration for unit testing)
        clanManager = new ClanManager();
        clanManager.initialize(address(gDollar), platformTreasury, CREATION_FEE, STAKE_AMOUNT);

        royaleEngine = new RoyaleEngine();
        royaleEngine.initialize(address(gDollar), address(clanManager), backendOperator);
        vm.stopPrank();

        // 3. Fund Test Users with G$ tokens
        gDollar.mint(alice, 100 * 10**18);
        gDollar.mint(bob, 100 * 10**18);
        gDollar.mint(charlie, 100 * 10**18);
    }

    // --- ClanManager Unit Tests ---

    /**
     * @notice Verifies successful clan creation via valid ERC-677 transferAndCall.
     */
    function test_Success_CreateClan() public {
        vm.startPrank(alice);
        
        // Encode payload data: string clanName
        bytes memory payload = abi.encode("Alpha Clan");
        // Encode final ERC-677 call: actionType 0 (Create), payload data
        bytes memory data = abi.encode(uint8(0), payload);

        // Track financial balances before execution
        uint256 treasuryBalanceBefore = gDollar.balanceOf(platformTreasury);
        uint256 aliceBalanceBefore = gDollar.balanceOf(alice);

        // Execute transferAndCall directly on the token contract
        gDollar.transferAndCall(address(clanManager), CREATION_FEE, data);

        // Assert contract states
        (uint256 id, string memory name, address leader, uint256 hp, uint256 totalMembers, bool isActive) = clanManager.clans(1);
        assertEq(id, 1);
        assertEq(name, "Alpha Clan");
        assertEq(leader, alice);
        assertEq(hp, 100);
        assertEq(totalMembers, 1);
        assertTrue(isActive);

        // Assert financial settlement correctness
        assertEq(gDollar.balanceOf(platformTreasury), treasuryBalanceBefore + CREATION_FEE);
        assertEq(gDollar.balanceOf(alice), aliceBalanceBefore - CREATION_FEE);
        vm.stopPrank();
    }

    /**
     * @notice Ensures clan creation fails if the user sends an insufficient fee amount.
     */
    function test_Revert_CreateClan_InsufficientAmount() public {
        vm.startPrank(alice);
        bytes memory payload = abi.encode("Beta Clan");
        bytes memory data = abi.encode(uint8(0), payload);

        // Expect custom error from ClanManager due to sending lower fee
        vm.expectRevert(ClanManager.InsufficientAmount.creator);
        gDollar.transferAndCall(address(clanManager), CREATION_FEE - 1, data);
        vm.stopPrank();
    }

    /**
     * @notice Verifies a user can successfully stake tokens and join an active clan.
     */
    function test_Success_JoinClan() public {
        // Establish a clan first via Alice
        vm.prank(alice);
        gDollar.transferAndCall(address(clanManager), CREATION_FEE, abi.encode(uint8(0), abi.encode("Alpha Clan")));

        // Bob joins the existing clan (ID: 1)
        vm.startPrank(bob);
        bytes memory payload = abi.encode(uint256(1)); // Target Clan ID
        bytes memory data = abi.encode(uint8(1), payload); // Action Type 1 = Join Clan

        uint256 contractEscrowBefore = gDollar.balanceOf(address(clanManager));

        gDollar.transferAndCall(address(clanManager), STAKE_AMOUNT, data);

        // Assert member mappings updated correctly
        (, uint256 clanId, , uint256 stakedAmount) = clanManager.players(bob);
        assertEq(clanId, 1);
        assertEq(stakedAmount, STAKE_AMOUNT);

        // Assert escrow safety balance increased inside contract execution
        assertEq(gDollar.balanceOf(address(clanManager)), contractEscrowBefore + STAKE_AMOUNT);
        vm.stopPrank();
    }

    /**
     * @notice Security Check: Guard contract against direct unauthenticated onTokenTransfer invocations.
     */
    function test_Revert_DirectCallback_Unauthorized() public {
        vm.startPrank(alice);
        // Direct calls not stemming from the official GoodDollar token address must revert securely
        vm.expectRevert(ClanManager.Unauthorized.creator);
        clanManager.onTokenTransfer(alice, STAKE_AMOUNT, abi.encode(uint8(1), abi.encode(uint256(1))));
        vm.stopPrank();
    }

    // --- RoyaleEngine Unit Tests ---

    /**
     * @notice Ensures only the authorized backend operator or owner can submit daily updates.
     */
    function test_Revert_ProcessDailyResolutions_Unauthorized() public {
        address[] memory users = new address[](1);
        users[0] = alice;
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;

        vm.prank(alice); // Unauthorized malicious hot-wallet actor
        vm.expectRevert(RoyaleEngine.Unauthorized.creator);
        royaleEngine.processDailyResolutions(users, statuses);
    }
}