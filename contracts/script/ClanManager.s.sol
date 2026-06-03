// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ClanManager
 * @dev Manages the creation of clans, player joining, and platform fee collection.
 * Uses UUPS upgradeability pattern and is protected against reentrancy attacks.
 */
contract ClanManager is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // --- State Variables ---
    
    IERC20 public goodDollarToken;
    address public platformTreasury; // The wallet receiving clan creation fees
    
    uint256 public clanCreationFee;
    uint256 public memberStakeAmount; // Refundable deposit required to join a clan
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
    event TreasuryUpdated(address newTreasury);
    event FeesUpdated(uint256 newCreationFee, uint256 newStakeAmount);

    // --- Custom Errors (Gas Optimization over require strings) ---
    
    error AlreadyInClan();
    error InvalidClanName();
    error ClanNotActive();
    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Prevents the implementation contract from being initialized directly
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract. Acts as the constructor for the proxy.
     * @param _gToken Address of the GoodDollar token.
     * @param _treasury Address of the platform treasury to collect fees.
     * @param _creationFee Amount of G$ required to create a clan.
     * @param _stakeAmount Amount of G$ required to join a clan (refundable).
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

    /**
     * @dev UUPS required function to authorize contract upgrades.
     * Only the owner can upgrade the contract.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice Creates a new clan and transfers the creation fee to the platform treasury.
     * @param _name The desired name of the clan.
     */
    function createClan(string memory _name) external nonReentrant {
        if (players[msg.sender].clanId != 0) revert AlreadyInClan();
        if (bytes(_name).length == 0) revert InvalidClanName();

        // Security: Use SafeERC20 to handle non-standard ERC20 implementations safely
        goodDollarToken.safeTransferFrom(msg.sender, platformTreasury, clanCreationFee);

        uint256 clanId = nextClanId++;
        
        clans[clanId] = Clan({
            id: clanId,
            name: _name,
            leader: msg.sender,
            hp: 100, // Default starting Health Points
            totalMembers: 1,
            isActive: true
        });

        players[msg.sender] = Player({
            wallet: msg.sender,
            clanId: clanId,
            dailyPoints: 0,
            stakedAmount: 0 // Leaders pay the fee, they do not stake initially
        });

        emit ClanCreated(clanId, _name, msg.sender, clanCreationFee);
    }

    /**
     * @notice Allows a player to join an existing active clan by staking a refundable deposit.
     * @param _clanId The ID of the clan to join.
     */
    function joinClan(uint256 _clanId) external nonReentrant {
        if (!clans[_clanId].isActive) revert ClanNotActive();
        if (players[msg.sender].clanId != 0) revert AlreadyInClan();

        // Security: Pull the stake amount into the contract (Escrow)
        goodDollarToken.safeTransferFrom(msg.sender, address(this), memberStakeAmount);

        clans[_clanId].totalMembers += 1;
        
        players[msg.sender] = Player({
            wallet: msg.sender,
            clanId: _clanId,
            dailyPoints: 0,
            stakedAmount: memberStakeAmount
        });

        emit PlayerJoined(_clanId, msg.sender, memberStakeAmount);
    }

    // --- Admin Functions ---

    /**
     * @notice Updates the platform treasury address.
     * @param _newTreasury The new address to receive fees.
     */
    function setPlatformTreasury(address _newTreasury) external onlyOwner {
        if (_newTreasury == address(0)) revert ZeroAddress();
        platformTreasury = _newTreasury;
        emit TreasuryUpdated(_newTreasury);
    }

    /**
     * @notice Updates the fees required for creation and staking.
     * @param _newCreationFee New fee to create a clan.
     * @param _newStakeAmount New stake amount to join a clan.
     */
    function setFees(uint256 _newCreationFee, uint256 _newStakeAmount) external onlyOwner {
        clanCreationFee = _newCreationFee;
        memberStakeAmount = _newStakeAmount;
        emit FeesUpdated(_newCreationFee, _newStakeAmount);
    }
}