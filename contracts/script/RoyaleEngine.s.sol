// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IClanManager {
    struct Clan {
        uint256 id;
        string name;
        address leader;
        uint256 hp;
        uint256 totalMembers;
        bool isActive;
    }
    struct Player {
        address wallet;
        uint256 clanId;
        uint256 dailyPoints;
        uint256 stakedAmount;
    }
    function clans(uint256 id) external view returns (uint256, string memory, address, uint256, uint256, bool);
    function players(address wallet) external view returns (address, uint256, uint256, uint256);
    function updateClanHP(uint256 clanId, uint256 newHP) external;
    function updatePlayerPoints(address wallet, uint256 newPoints) external;
    function slashPlayerStake(address wallet, uint256 penaltyAmount) external;
}

/**
 * @title RoyaleEngine
 * @dev Handles the daily puzzle mechanics, streak tracking, slashing penalities, and reward distributions.
 * @notice All code comments are strictly maintained in English for production readiness.
 */
contract RoyaleEngine is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // --- State Variables ---

    IERC20 public goodDollarToken;
    IClanManager public clanManager;
    address public trustedBackendOperator; // Authorized hot-wallet for submitting daily AI verification results

    uint256 public basePointsPerSolve;
    uint256 public slashPercentage; // e.g., 500 for 5% (basis points)
    uint256 public totalRewardPool; // Accumulated G$ tokens from slashed inactive players

    mapping(address => uint256) public playerDailyStreaks;
    mapping(address => uint256) public lastActiveDay;
    mapping(address => bool) public hasFreezeActive; // Tracks if freeze elixir protects player today [cite: 1, 2]

    // --- Events ---

    event DailyStatusProcessed(address indexed player, bool indexed solved, uint256 pointsAwarded, uint256 amountSlashed);
    event RewardPoolDistributed(uint256 totalAmount, uint256 distributedTimestamp);
    event OperatorUpdated(address indexed newOperator);

    // --- Custom Errors ---

    error Unauthorized();
    error ZeroAddress();
    error ArrayLengthMismatch();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract logic and sets core parameters.
     * @param _gToken Address of the GoodDollar token.
     * @param _clanManager Address of the ClanManager contract.
     * @param _operator Address of the backend verification wallet.
     */
    function initialize(
        address _gToken,
        address _clanManager,
        address _operator
    ) public initializer {
        if (_gToken == address(0) || _clanManager == address(0) || _operator == address(0)) revert ZeroAddress();

        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        goodDollarToken = IERC20(_gToken);
        clanManager = IClanManager(_clanManager);
        trustedBackendOperator = _operator;

        basePointsPerSolve = 10;
        slashPercentage = 200; // Default 2% slashing penalty per missed day 
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // --- Modifiers ---

    modifier onlyOperator() {
        if (msg.sender != trustedBackendOperator && msg.sender != owner()) revert Unauthorized();
        _;
    }

    // --- Core External Functions ---

    /**
     * @notice Batch updates the daily resolution statuses for players after AI verification closes.
     * @dev Called daily by the automated backend operator script.
     * @param _players Array of player wallet addresses to process.
     * @param _statuses Array of booleans indicating if the corresponding player solved today's puzzle.
     */
    function processDailyResolutions(
        address[] calldata _players,
        bool[] calldata _statuses
    ) external onlyOperator nonReentrant {
        if (_players.length != _statuses.length) revert ArrayLengthMismatch();

        uint256 totalPlayers = _players.length;
        for (uint256 i = 0; i < totalPlayers; i++) {
            address playerAddress = _players[i];
            bool solved = _statuses[i];

            (, uint256 clanId, uint256 currentPoints, uint256 stakedAmount) = clanManager.players(playerAddress);
            
            // Skip processing if the user is not registered in any clan
            if (clanId == 0) continue;

            if (solved) {
                // 1. Handle Successful Solve Logic
                playerDailyStreaks[playerAddress] += 1;
                uint256 pointsEarned = basePointsPerSolve;
                
                // Extra bonus calculation can be dynamically integrated here
                clanManager.updatePlayerPoints(playerAddress, currentPoints + pointsEarned);
                
                emit DailyStatusProcessed(playerAddress, true, pointsEarned, 0);
            } else {
                // 2. Handle Inactive / Failed Miss Logic 
                playerDailyStreaks[playerAddress] = 0; // Reset streak on failure

                // Check if the user is protected by a Freeze Elixir purchased from the store [cite: 1, 2]
                if (hasFreezeActive[playerAddress]) {
                    hasFreezeActive[playerAddress] = false; // Consume the freeze item protection
                    emit DailyStatusProcessed(playerAddress, false, 0, 0);
                    continue;
                }

                // Apply slashing penalty on the player's locked stake amount 
                uint256 penalty = 0;
                if (stakedAmount > 0) {
                    penalty = (stakedAmount * slashPercentage) / 10000;
                    if (penalty > 0) {
                        // Transfer the penalty from ClanManager escrow or handle internally
                        clanManager.slashPlayerStake(playerAddress, penalty);
                        totalRewardPool += penalty; // Route penalty into global active players reward pool 
                    }
                }

                // Deduct Clan Health Points (HP) dynamically if a member fails
                (, , , uint256 clanHP, , ) = clanManager.clans(clanId);
                if (clanHP >= 5) {
                    clanManager.updateClanHP(clanId, clanHP - 5);
                } else if (clanHP > 0) {
                    clanManager.updateClanHP(clanId, 0); // Clan is eliminated from the active bracket
                }

                emit DailyStatusProcessed(playerAddress, false, 0, penalty);
            }
        }
    }

    /**
     * @notice Dynamically updates the global freeze elixir flag for a player.
     * @dev Will be triggered internally by the Store contract upon successful purchase.
     */
    function activatePlayerFreeze(address _player) external {
        // Implementation will interface securely with Store.sol in Phase 4 
        hasFreezeActive[_player] = true;
    }

    // --- Admin Configuration Functions ---

    /**
     * @notice Updates the trusted hot-wallet operator address for automated updates.
     */
    function setTrustedOperator(address _newOperator) external onlyOwner {
        if (_newOperator == address(0)) revert ZeroAddress();
        trustedBackendOperator = _newOperator;
        emit OperatorUpdated(_newOperator);
    }
}