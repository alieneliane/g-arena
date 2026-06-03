// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title IERC677Receiver
 * @dev Interface for receiving ERC-677 token transfers natively without a separate approval step.
 */
interface IERC677Receiver {
    function onTokenTransfer(address from, uint256 value, bytes calldata data) external returns (bool);
}

/**
 * @title ClanManager
 * @dev Manages clan creation and player staking using the G$ ERC-677 transferAndCall pattern.
 */
contract ClanManager is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable, IERC677Receiver {
    using SafeERC20 for IERC20;

    // --- State Variables ---
    IERC20 public goodDollarToken;
    address public platformTreasury;
    
    uint256 public clanCreationFee;
    uint256 public memberStakeAmount;
    uint256 public nextClanId;

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

    mapping(uint256 => Clan) public clans;
    mapping(address => Player) public players;

    // --- Events ---
    event ClanCreated(uint256 indexed clanId, string name, address indexed leader, uint256 feePaid);
    event PlayerJoined(uint256 indexed clanId, address indexed player, uint256 amountStaked);

    // --- Custom Errors ---
    error AlreadyInClan();
    error InvalidClanName();
    error ClanNotActive();
    error ZeroAddress();
    error Unauthorized();
    error InvalidAction();
    error InsufficientAmount();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the proxy state variables.
     */
    function initialize(
        address _gToken, 
        address _treasury, 
        uint256 _creationFee, 
        uint256 _stakeAmount
    ) public initializer {
        if (_gToken == address(0) || _treasury == address(0)) revert ZeroAddress();

        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        
        goodDollarToken = IERC20(_gToken);
        platformTreasury = _treasury;
        clanCreationFee = _creationFee;
        memberStakeAmount = _stakeAmount;
        nextClanId = 1;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice Callback function automatically triggered by the G$ token contract during transferAndCall.
     * @dev Decodes incoming bytes payload to dynamically orchestrate either clan creation or member staking.
     * @param from The address initiating the token transfer.
     * @param value The amount of G$ tokens received by this contract.
     * @param data Encoded payload parameter specifying the action type and nested data parameters.
     */
    function onTokenTransfer(address from, uint256 value, bytes calldata data) external override nonReentrant returns (bool) {
        // Security check: Verify that the caller is exclusively the official GoodDollar token contract
        if (msg.sender != address(goodDollarToken)) revert Unauthorized();

        // Decode the execution layout: actionType 0 = Create Clan, 1 = Join Clan
        (uint8 actionType, bytes memory payload) = abi.decode(data, (uint8, bytes));

        if (actionType == 0) {
            // Process dynamic clan registration logic
            if (value < clanCreationFee) revert InsufficientAmount();
            string memory clanName = abi.decode(payload, (string));
            _createClan(from, clanName, value);
        } else if (actionType == 1) {
            // Process secure member entry staking logic
            if (value < memberStakeAmount) revert InsufficientAmount();
            uint256 clanId = abi.decode(payload, (uint256));
            _joinClan(from, clanId, value);
        } else {
            revert InvalidAction();
        }

        return true;
    }

    // --- Internal Execution Logic ---

    /**
     * @dev Registers a new clan state and routes the incoming fee directly to the platform treasury.
     */
    function _createClan(address creator, string memory _name, uint256 _feePaid) internal {
        if (players[creator].clanId != 0) revert AlreadyInClan();
        if (bytes(_name).length == 0) revert InvalidClanName();

        // Transfer the incoming creation fee safely to the platform's protocol treasury wallet
        goodDollarToken.safeTransfer(platformTreasury, _feePaid);

        uint256 clanId = nextClanId++;
        
        clans[clanId] = Clan({
            id: clanId,
            name: _name,
            leader: creator,
            hp: 100,
            totalMembers: 1,
            isActive: true
        });

        players[creator] = Player({
            wallet: creator,
            clanId: clanId,
            dailyPoints: 0,
            stakedAmount: 0 
        });

        emit ClanCreated(clanId, _name, creator, _feePaid);
    }

    /**
     * @dev Stakes the incoming user deposit into contract escrow and updates active member mappings.
     */
    function _joinClan(address player, uint256 _clanId, uint256 _stakeAmount) internal {
        if (!clans[_clanId].isActive) revert ClanNotActive();
        if (players[player].clanId != 0) revert AlreadyInClan();

        // Tokens natively remain in this contract's balance to serve as an immutable commitment escrow
        clans[_clanId].totalMembers += 1;
        
        players[player] = Player({
            wallet: player,
            clanId: _clanId,
            dailyPoints: 0,
            stakedAmount: _stakeAmount
        });

        emit PlayerJoined(_clanId, player, _stakeAmount);
    }
}               