// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/Address.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/cryptography/ECDSA.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IAnnexStake.sol";
import "./interfaces/IDocuments.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract AnnexFixedSwap is ReentrancyGuardUpgradeSafe, Ownable {

    mapping (bytes32 => uint) internal config;
    IDocuments public documents; // for storing documents
    IERC20 public annexToken;
    address public treasury;
    uint256 public threshold = 100000 ether; // 100000 ANN

    using SafeMath for uint;
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using Address for address;

    bytes32 internal constant TxFeeRatio            = bytes32("TxFeeRatio");
    bytes32 internal constant MinValueOfBotHolder   = bytes32("MinValueOfBotHolder");
    bytes32 internal constant BotToken              = bytes32("BotToken");
    bytes32 internal constant StakeContract         = bytes32("StakeContract");

    struct AuctionReq {
        // auction name
        // string name;
        // address of sell token
        address _auctioningToken;
        // address of buy token
        address _biddingToken;
        // total amount of _auctioningToken
        uint amountTotal0;
        // total amount of _biddingToken
        uint amountTotal1;
        // the timestamp in seconds the auction will open
        uint auctionStartDate;
        // the timestamp in seconds the auction will be closed
        uint auctionEndDate;
        // the delay timestamp in seconds when buyers can claim after auction filled
        uint claimAt;
        uint maxAmount1PerWallet;
        bool onlyBot;
        bool enableWhiteList;
    }

    struct Auction {
        // auction name
        // string name;
        // creator of the auction
        address payable creator;
        // address of sell token
        address _auctioningToken;
        // address of buy token
        address _biddingToken;
        // total amount of _auctioningToken
        uint amountTotal0;
        // total amount of _biddingToken
        uint amountTotal1;
        // the timestamp in seconds the auction will open
        uint auctionStartDate;
        // the timestamp in seconds the auction will be closed
        uint auctionEndDate;
        // the delay timestamp in seconds when buyers can claim after auction filled
        uint claimAt;
        // whether or not whitelist is enable
        bool enableWhiteList;
    }

    struct AuctionAbout {
        string website;
        string description;
        string telegram;
        string discord;
        string medium;
        string twitter;
    }

    Auction[] public auctions;

    // auction auctionId => the timestamp which the auction filled at
    mapping(uint => uint) public filledAtP;
    // auction auctionId => swap amount of _auctioningToken
    mapping(uint => uint) public amountSwap0P;
    // auction auctionId => swap amount of _biddingToken
    mapping(uint => uint) public amountSwap1P;
    // auction auctionId => the swap auction only allow BOT holder to take part in
    mapping(uint => bool) public onlyBotHolderP;
    // auction auctionId => maximum swap amount1 per wallet, if the value is not set, the default value is zero
    mapping(uint => uint) public maxAmount1PerWalletP;
    // team address => auction auctionId => whether or not creator's auction has been claimed
    mapping(address => mapping(uint => bool)) public creatorClaimed;
    // user address => auction auctionId => swapped amount of _auctioningToken
    mapping(address => mapping(uint => uint)) public myAmountSwapped0;
    // user address => auction auctionId => swapped amount of _biddingToken
    mapping(address => mapping(uint => uint)) public myAmountSwapped1;
    // user address => auction auctionId => whether or not my auction has been claimed
    mapping(address => mapping(uint => bool)) public myClaimed;

    // auction auctionId => account => whether or not in white list
    mapping(uint => mapping(address => bool)) public whitelistP;
    // auction auctionId => transaction fee
    mapping(uint => uint) public txFeeP;

    event NewAuction(
        uint256 indexed auctionId,
        address _auctioningToken,
        address _biddingToken,
        uint256 auctionStartDate,
        uint256 auctionEndDate,
        address auctioner_address,
        uint256 _auctionedSellAmount,
        uint256 amountMax1,
        uint256 amountMin1,
        uint claimAt,
        uint maxAmount1PerWallet
    );
    event NewSellOrder(uint indexed auctionId, address indexed sender, uint amount0, uint amount1, uint txFee);
    event Claimed(uint indexed auctionId, address indexed sender, uint amount0, uint txFee);
    event UserClaimed(uint indexed auctionId, address indexed sender, uint amount0);
    event AuctionDetails(
        uint256 indexed auctionId,
        string[6] social
    );

    // function initialize() public initializer {
    //     super.__Ownable_init();
    //     super.__ReentrancyGuard_init();

    //     config[TxFeeRatio] = 0.005 ether; // 0.5%
    //     config[MinValueOfBotHolder] = 60 ether;

    //     config[BotToken] = uint(0xA9B1Eb5908CfC3cdf91F9B8B3a74108598009096); // AUCTION
    //     config[StakeContract] = uint(0x98945BC69A554F8b129b09aC8AfDc2cc2431c48E);
    // }

    // function initialize_bsc() public {
    //     initialize();

    //     config[BotToken] = uint(0x1188d953aFC697C031851169EEf640F23ac8529C); // AUCTION
    //     config[StakeContract] = uint(0x1dd665ba1591756aa87157F082F175bDcA9fB91a);
    // }

    function initiateAuction(AuctionReq memory auctionReq, address[] memory whitelist_) external nonReentrant {

        // Auctioner can init an auction if he has 100 Ann
        require(
            annexToken.balanceOf(msg.sender) >= threshold,
            "NOT_ENOUGH_ANN"
        );
        if (threshold > 0) {
            annexToken.safeTransferFrom(msg.sender, treasury, threshold);
        }

        uint auctionId = auctions.length;
        require(tx.origin == msg.sender, "disallow contract caller");
        require(auctionReq.amountTotal0 != 0, "invalid amountTotal0");
        require(auctionReq.amountTotal1 != 0, "invalid amountTotal1");
        require(auctionReq.auctionStartDate >= now, "invalid auctionStartDate");
        require(auctionReq.auctionEndDate > auctionReq.auctionStartDate, "invalid auctionEndDate");
        require(auctionReq.claimAt == 0 || auctionReq.claimAt >= auctionReq.auctionEndDate, "invalid auctionEndDate");
        // require(bytes(auctionReq.name).length <= 15, "length of name is too long");

        if (auctionReq.maxAmount1PerWallet != 0) {
            maxAmount1PerWalletP[auctionId] = auctionReq.maxAmount1PerWallet;
        }
        if (auctionReq.onlyBot) {
            onlyBotHolderP[auctionId] = auctionReq.onlyBot;
        }

        // transfer amount of _auctioningToken to this contract
        IERC20  __auctioningToken = IERC20(auctionReq._auctioningToken);
        uint _auctioningTokenBalanceBefore = __auctioningToken.balanceOf(address(this));
        __auctioningToken.safeTransferFrom(msg.sender, address(this), auctionReq.amountTotal0);
        require(
            __auctioningToken.balanceOf(address(this)).sub(_auctioningTokenBalanceBefore) == auctionReq.amountTotal0,
            "not support deflationary token"
        );

        if (auctionReq.enableWhiteList) {
            require(whitelist_.length > 0, "no whitelist imported");
            _addWhitelist(auctionId, whitelist_);
        }

        Auction memory auction;
        // auction.name = auctionReq.name;
        auction.creator = msg.sender;
        auction._auctioningToken = auctionReq._auctioningToken;
        auction._biddingToken = auctionReq._biddingToken;
        auction.amountTotal0 = auctionReq.amountTotal0;
        auction.amountTotal1 = auctionReq.amountTotal1;
        auction.auctionStartDate = auctionReq.auctionStartDate;
        auction.auctionEndDate = auctionReq.auctionEndDate;
        auction.claimAt = auctionReq.claimAt;
        auction.enableWhiteList = auctionReq.enableWhiteList;
        auctions.push(auction);

        emit NewAuction(
            auctionId,
            auctionReq._auctioningToken,
            auctionReq._biddingToken,
            auctionReq.auctionStartDate,
            auctionReq.auctionEndDate,
            msg.sender,
            auctionReq.amountTotal0,
            auctionReq.amountTotal0,
            auctionReq.amountTotal1,
            auctionReq.claimAt,
            auctionReq.maxAmount1PerWallet
        );

        /**
        * socials[0] = webiste link 
        * socials[1] = description 
        * socials[2] = telegram link 
        * socials[3] = discord link 
        * socials[4] = medium link 
        * socials[5] = twitter link 
        **/
        string[6] memory socials = [auctionReq.about.website,auctionReq.about.description,auctionReq.about.telegram,auctionReq.about.discord,auctionReq.about.medium,auctionReq.about.twitter];
        emit AuctionDetails(
            auctionId,
            socials
        );

    }

    function swap(uint auctionId, uint amount1) external payable
        nonReentrant
        isAuctionExist(auctionId)
        isAuctionNotClosed(auctionId)
        checkBotHolder(auctionId)
    {
        address payable sender = msg.sender;
        require(tx.origin == msg.sender, "disallow contract caller");
        Auction memory auction = auctions[auctionId];

        if (auction.enableWhiteList) {
            require(whitelistP[auctionId][sender], "sender not in whitelist");
        }
        require(auction.auctionStartDate <= now, "auction not open");
        require(auction.amountTotal1 > amountSwap1P[auctionId], "swap amount is zero");

        // check if amount1 is exceeded
        uint excessAmount1 = 0;
        uint _amount1 = auction.amountTotal1.sub(amountSwap1P[auctionId]);
        if (_amount1 < amount1) {
            excessAmount1 = amount1.sub(_amount1);
        } else {
            _amount1 = amount1;
        }

        // check if amount0 is exceeded
        uint amount0 = _amount1.mul(auction.amountTotal0).div(auction.amountTotal1);
        uint _amount0 = auction.amountTotal0.sub(amountSwap0P[auctionId]);
        if (_amount0 > amount0) {
            _amount0 = amount0;
        }

        amountSwap0P[auctionId] = amountSwap0P[auctionId].add(_amount0);
        amountSwap1P[auctionId] = amountSwap1P[auctionId].add(_amount1);
        myAmountSwapped0[sender][auctionId] = myAmountSwapped0[sender][auctionId].add(_amount0);
        // check if swapped amount of _biddingToken is exceeded maximum allowance
        if (maxAmount1PerWalletP[auctionId] != 0) {
            require(
                myAmountSwapped1[sender][auctionId].add(_amount1) <= maxAmount1PerWalletP[auctionId],
                "swapped amount of _biddingToken is exceeded maximum allowance"
            );
            myAmountSwapped1[sender][auctionId] = myAmountSwapped1[sender][auctionId].add(_amount1);
        }

        if (auction.amountTotal1 == amountSwap1P[auctionId]) {
            filledAtP[auctionId] = now;
        }

        // transfer amount of _biddingToken to this contract
        if (auction._biddingToken == address(0)) {
            require(msg.value == amount1, "invalid amount of ETH");
        } else {
            IERC20(auction._biddingToken).safeTransferFrom(sender, address(this), amount1);
        }

        if (auction.claimAt == 0) {
            if (_amount0 > 0) {
                // send _auctioningToken to sender
                IERC20(auction._auctioningToken).safeTransfer(sender, _amount0);
            }
        }
        if (excessAmount1 > 0) {
            // send excess amount of _biddingToken back to sender
            if (auction._biddingToken == address(0)) {
                sender.transfer(excessAmount1);
            } else {
                IERC20(auction._biddingToken).safeTransfer(sender, excessAmount1);
            }
        }

        // send _biddingToken to creator
        uint256 txFee = 0;
        uint256 _actualAmount1 = _amount1;
        if (auction._biddingToken == address(0)) {
            txFee = _amount1.mul(getTxFeeRatio()).div(1 ether);
            txFeeP[auctionId] += txFee;
            _actualAmount1 = _amount1.sub(txFee);
            auction.creator.transfer(_actualAmount1);
        } else {
            IERC20(auction._biddingToken).safeTransfer(auction.creator, _actualAmount1);
        }

        emit NewSellOrder(auctionId, sender, _amount0, _actualAmount1, txFee);
    }

    function creatorClaim(uint auctionId) external
        nonReentrant
        isAuctionExist(auctionId)
        isAuctionClosed(auctionId)
    {
        Auction memory auction = auctions[auctionId];
        require(!creatorClaimed[auction.creator][auctionId], "claimed");
        creatorClaimed[auction.creator][auctionId] = true;

        if (txFeeP[auctionId] > 0) {
            if (auction._biddingToken == address(0)) {
                // deposit transaction fee to staking contract
                IAnnexStake(getStakeContract()).depositReward{value: txFeeP[auctionId]}();
            } else {
                IERC20(auction._biddingToken).safeTransfer(getStakeContract(), txFeeP[auctionId]);
            }
        }

        uint unSwapAmount0 = auction.amountTotal0 - amountSwap0P[auctionId];
        if (unSwapAmount0 > 0) {
            IERC20(auction._auctioningToken).safeTransfer(auction.creator, unSwapAmount0);
        }

        emit Claimed(auctionId, msg.sender, unSwapAmount0, txFeeP[auctionId]);
    }

    function userClaim(uint auctionId) external
        nonReentrant
        isAuctionExist(auctionId)
        isClaimReady(auctionId)
    {
        Auction memory auction = auctions[auctionId];
        address sender = msg.sender;
        require(!myClaimed[sender][auctionId], "claimed");
        myClaimed[sender][auctionId] = true;
        if (myAmountSwapped0[sender][auctionId] > 0) {
            // send _auctioningToken to sender
            IERC20(auction._auctioningToken).safeTransfer(msg.sender, myAmountSwapped0[sender][auctionId]);
        }
        emit UserClaimed(auctionId, sender, myAmountSwapped0[sender][auctionId]);
    }

    function _addWhitelist(uint auctionId, address[] memory whitelist_) private {
        for (uint i = 0; i < whitelist_.length; i++) {
            whitelistP[auctionId][whitelist_[i]] = true;
        }
    }

    function addWhitelist(uint auctionId, address[] memory whitelist_) external {
        require(owner() == msg.sender || auctions[auctionId].creator == msg.sender, "no permission");
        _addWhitelist(auctionId, whitelist_);
    }

    function removeWhitelist(uint auctionId, address[] memory whitelist_) external {
        require(owner() == msg.sender || auctions[auctionId].creator == msg.sender, "no permission");
        for (uint i = 0; i < whitelist_.length; i++) {
            delete whitelistP[auctionId][whitelist_[i]];
        }
    }

    function getAuctionCount() public view returns (uint) {
        return auctions.length;
    }

    function getTxFeeRatio() public view returns (uint) {
        return config[TxFeeRatio];
    }

    function getMinValueOfBotHolder() public view returns (uint) {
        return config[MinValueOfBotHolder];
    }

    function getBotToken() public view returns (address) {
        return address(config[BotToken]);
    }

    function getStakeContract() public view returns (address) {
        return address(config[StakeContract]);
    }

    modifier isAuctionClosed(uint auctionId) {
        require(auctions[auctionId].auctionEndDate <= now, "this auction is not closed");
        _;
    }

    modifier isAuctionNotClosed(uint auctionId) {
        require(auctions[auctionId].auctionEndDate > now, "this auction is closed");
        _;
    }

    modifier isClaimReady(uint auctionId) {
        require(auctions[auctionId].claimAt != 0, "invalid claim");
        require(auctions[auctionId].claimAt <= now, "claim not ready");
        _;
    }

    modifier isAuctionExist(uint auctionId) {
        require(auctionId < auctions.length, "this auction does not exist");
        _;
    }

    modifier checkBotHolder(uint auctionId) {
        if (onlyBotHolderP[auctionId]) {
            require(
                IERC20(getBotToken()).balanceOf(msg.sender) >= getMinValueOfBotHolder(),
                "Auction is not enough"
            );
        }
        _;
    }

    //--------------------------------------------------------
    // Getter & Setters
    //--------------------------------------------------------

    function setThreshold(uint256 _threshold) external onlyOwner {
        threshold = _threshold;
    }

    function setAnnexAddress(address _annexToken) external onlyOwner {
        annexToken = IERC20(_annexToken);
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    function setDocumentAddress(address _document) external onlyOwner {
        documents = IDocuments(_document);
    }

    //--------------------------------------------------------
    // Documents
    //--------------------------------------------------------

    function setDocument(string calldata _name, string calldata _data)
        external
        onlyOwner()
    {
        documents._setDocument(_name, _data);
    }

    function getDocumentCount() external view returns (uint256) {
        return documents.getDocumentCount();
    }

    function getAllDocuments() external view returns (bytes memory) {
        return documents.getAllDocuments();
    }

    function getDocumentName(uint256 _auctionId)
        external
        view
        returns (string memory)
    {
        return documents.getDocumentName(_auctionId);
    }

    function getDocument(string calldata _name)
        external
        view
        returns (string memory, uint256)
    {
        return documents.getDocument(_name);
    }

    function removeDocument(string calldata _name) external {
        documents._removeDocument(_name);
    }

    //--------------------------------------------------------
    // Configurable
    //--------------------------------------------------------

    function getConfig(bytes32 key) public view returns (uint) {
        return config[key];
    }
    function getConfig(bytes32 key, uint auctionId) public view returns (uint) {
        return config[bytes32(uint(key) ^ auctionId)];
    }
    function getConfig(bytes32 key, address addr) public view returns (uint) {
        return config[bytes32(uint(key) ^ uint(addr))];
    }
    function _setConfig(bytes32 key, uint value) internal {
        if(config[key] != value)
            config[key] = value;
    }
    function _setConfig(bytes32 key, uint auctionId, uint value) internal {
        _setConfig(bytes32(uint(key) ^ auctionId), value);
    }
    function _setConfig(bytes32 key, address addr, uint value) internal {
        _setConfig(bytes32(uint(key) ^ uint(addr)), value);
    }
    function setConfig(bytes32 key, uint value) external onlyOwner {
        _setConfig(key, value);
    }
    function setConfig(bytes32 key, uint auctionId, uint value) external onlyOwner {
        _setConfig(bytes32(uint(key) ^ auctionId), value);
    }
    function setConfig(bytes32 key, address addr, uint value) public onlyOwner {
        _setConfig(bytes32(uint(key) ^ uint(addr)), value);
    }
}