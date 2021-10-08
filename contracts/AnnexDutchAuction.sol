// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IDocuments.sol";
import "./interfaces/IAnnexStake.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract AnnexDutchAuction is ReentrancyGuard, Ownable {

    mapping (bytes32 => uint) internal config;
    IDocuments public documents; // for storing documents
    IERC20 public annexToken;
    address public treasury;
    uint256 public threshold = 100000 ether; // 100000 ANN

    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address;

    bytes32 internal constant TxFeeRatio =              bytes32("TxFeeRatio");
    bytes32 internal constant MinValueOfBotHolder =     bytes32("MinValueOfBotHolder");
    bytes32 internal constant BotToken =                bytes32("BotToken");
    bytes32 internal constant StakeContract =           bytes32("StakeContract");

    struct AuctionReq {
        // auction name
        // string name;
        // creator of the auction
        // address payable creator;
        // address of sell token
        address _auctioningToken;
        // address of buy token
        address _biddingToken;
        // total amount of _auctioningToken
        uint _auctionedSellAmount;
        // maximum amount of ETH that creator want to swap
        uint amountMax1;
        // minimum amount of ETH that creator want to swap
        uint amountMin1;
        // uint amountReserve1;
        // how many times a bid will decrease it's price
        uint times;
        // the timestamp in seconds the auction will open
        uint auctionStartDate;
        // the timestamp in seconds the auction will be closed
        uint auctionEndDate;
        bool onlyBot;
        // whether or not whitelist is enable
        bool enableWhiteList;
        // About Info in request
        AuctionAbout about;
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
        // total amount of sell token
        uint _auctionedSellAmount;
        // maximum amount of ETH that creator want to swap
        uint amountMax1;
        // minimum amount of ETH that creator want to swap
        uint amountMin1;
//        uint amountReserve1;
        // how many times a bid will decrease it's price
        uint times;
        // the duration in seconds the auction will be closed
        uint duration;
        // the timestamp in seconds the auction will open
        uint auctionStartDate;
        // the timestamp in seconds the auction will be closed
        uint auctionEndDate;
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

    // auction auctionId => amount of sell token has been swap
    mapping(uint => uint) public amountSwap0P;
    // auction auctionId => amount of ETH has been swap
    mapping(uint => uint) public amountSwap1P;
    // auction auctionId => a flag that if creator is claimed the auction
    mapping(uint => bool) public creatorClaimedP;
    // auction auctionId => the swap auction only allow BOT holder to take part in
    mapping(uint => bool) public onlyBotHolderP;

    mapping(uint => uint) public lowestBidPrice;
    // bidder address => auction auctionId => whether or not bidder claimed
    mapping(address => mapping(uint => bool)) public bidderClaimedP;
    // bidder address => auction auctionId => swapped amount of _auctioningToken
    mapping(address => mapping(uint => uint)) public myAmountSwap0P;
    // bidder address => auction auctionId => swapped amount of _biddingToken
    mapping(address => mapping(uint => uint)) public myAmountSwap1P;

    // creator address => auction auctionId + 1. if the result is 0, the account don't create any auction.
    mapping(address => uint) public myCreatedP;

    bool public enableWhiteList;
    // auction auctionId => account => whether or not allow swap
    mapping(uint => mapping(address => bool)) public whitelistP;

    event Created(uint indexed auctionId, address indexed sender, Auction auction);
    event Bid(uint indexed auctionId, address indexed sender, uint _minBuyAmounts, uint _sellAmounts);
    event Claimed(uint indexed auctionId, address indexed sender, uint unFilled_minBuyAmounts);
    event AuctionDetails(
        uint256 indexed auctionId,
        string[6] social
    );

    // function initialize() public initializer {
    //     super.__Ownable_init();
    //     super.__ReentrancyGuard_init();

    //     config[TxFeeRatio] = 0.015 ether;
    //     config[MinValueOfBotHolder] = 60 ether;
    //     config[BotToken] = uint(0xA9B1Eb5908CfC3cdf91F9B8B3a74108598009096);
    //     config[StakeContract] = uint(0x98945BC69A554F8b129b09aC8AfDc2cc2431c48E);
    // }

    // function initialize_rinkeby() public {
    //     initialize();

    //     config[BotToken] = uint(0x5E26FA0FE067d28aae8aFf2fB85Ac2E693BD9EfA);
    //     config[StakeContract] = uint(0xa77A9FcbA2Ae5599e0054369d1655D186020ECE1);
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

        require(tx.origin == msg.sender, "disallow contract caller");
        require(auctionReq._auctionedSellAmount != 0, "the value of _auctionedSellAmount is zero");
        require(auctionReq.amountMin1 != 0, "the value of amountMax1 is zero");
        require(auctionReq.amountMax1 != 0, "the value of amountMin1 is zero");
        require(auctionReq.amountMax1 > auctionReq.amountMin1, "amountMax1 should larger than amountMin1");
        // require(auctionReq.auctionStartDate <= auctionReq.auctionEndDate && auctionReq.auctionEndDate.sub(auctionReq.auctionStartDate) < 7 days, "invalid closed");
        require(auctionReq.times != 0, "the value of times is zero");
        // require(bytes(auctionReq.name).length <= 15, "the length of name is too long");

        uint auctionId = auctions.length;

        // transfer amount of _auctioningToken to this contract
        IERC20  __auctioningToken = IERC20(auctionReq._auctioningToken);
        uint _auctioningTokenBalanceBefore = __auctioningToken.balanceOf(address(this));
        __auctioningToken.safeTransferFrom(msg.sender, address(this), auctionReq._auctionedSellAmount);
        require(
            __auctioningToken.balanceOf(address(this)).sub(_auctioningTokenBalanceBefore) == auctionReq._auctionedSellAmount,
            "not support deflationary token"
        );

        if (auctionReq.enableWhiteList) {
            require(whitelist_.length > 0, "no whitelist imported");
            _addWhitelist(auctionId, whitelist_);
        }

        // creator auction
        Auction memory auction;
        // auction.name = auctionReq.name;
        auction.creator = msg.sender;
        auction._auctioningToken = auctionReq._auctioningToken;
        auction._biddingToken = auctionReq._biddingToken;
        auction._auctionedSellAmount = auctionReq._auctionedSellAmount;
        auction.amountMax1 = auctionReq.amountMax1;
        auction.amountMin1 = auctionReq.amountMin1;
//        auction.amountReserve1 = auctionReq.amountReserve1;
        auction.times = auctionReq.times;
        auction.duration = auctionReq.auctionEndDate.sub(auctionReq.auctionStartDate);
        auction.auctionStartDate = auctionReq.auctionStartDate;
        auction.auctionEndDate = auctionReq.auctionEndDate;
        auction.enableWhiteList = auctionReq.enableWhiteList;
        auctions.push(auction);

        if (auctionReq.onlyBot) {
            onlyBotHolderP[auctionId] = auctionReq.onlyBot;
        }

        myCreatedP[msg.sender] = auctions.length;

        emit Created(auctionId, msg.sender, auction);

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

    function placeSellOrders(
        // auction auctionId
        uint auctionId,
        // amount of _auctioningToken want to bid
        uint _minBuyAmounts,
        // amount of _biddingToken
        uint _sellAmounts
    ) external payable
        nonReentrant
        isAuctionExist(auctionId)
        checkBotHolder(auctionId)
        isAuctionNotClosed(auctionId)
    {
        address payable sender = msg.sender;
        require(tx.origin == msg.sender, "disallow contract caller");
        if (enableWhiteList) {
            require(whitelistP[auctionId][sender], "sender not in whitelist");
        }
        Auction memory auction = auctions[auctionId];
        require(auction.auctionStartDate <= now, "auction not open");
        require(_minBuyAmounts != 0, "the value of _minBuyAmounts is zero");
        require(_sellAmounts != 0, "the value of _sellAmounts is zero");
        require(auction._auctionedSellAmount > amountSwap0P[auctionId], "swap amount is zero");

        // calculate price
        uint curPrice = currentPrice(auctionId);
        uint bidPrice = _sellAmounts.mul(1 ether).div(_minBuyAmounts);
        require(bidPrice >= curPrice, "the bid price is lower than the current price");

        if (lowestBidPrice[auctionId] == 0 || lowestBidPrice[auctionId] > bidPrice) {
            lowestBidPrice[auctionId] = bidPrice;
        }

        address _biddingToken = auction._biddingToken;
        if (_biddingToken == address(0)) {
            require(_sellAmounts == msg.value, "invalid ETH amount");
        } else {
            IERC20(_biddingToken).safeTransferFrom(sender, address(this), _sellAmounts);
        }

        _swap(sender, auctionId, _minBuyAmounts, _sellAmounts);

        emit Bid(auctionId, sender, _minBuyAmounts, _sellAmounts);
    }

    function creatorClaim(uint auctionId) external
        nonReentrant
        isAuctionExist(auctionId)
        isAuctionClosed(auctionId)
    {
        address payable creator = msg.sender;
        require(isCreator(creator, auctionId), "sender is not auction creator");
        require(!creatorClaimedP[auctionId], "creator has claimed this auction");
        creatorClaimedP[auctionId] = true;

        // remove ownership of this auction from creator
        delete myCreatedP[creator];

        // calculate un-filled _minBuyAmounts
        Auction memory auction = auctions[auctionId];
        uint unFilled_minBuyAmounts = auction._auctionedSellAmount.sub(amountSwap0P[auctionId]);
        if (unFilled_minBuyAmounts > 0) {
            // transfer un-filled amount of _auctioningToken back to creator
            IERC20(auction._auctioningToken).safeTransfer(creator, unFilled_minBuyAmounts);
        }

        // send _biddingToken to creator
        uint _sellAmounts = lowestBidPrice[auctionId].mul(amountSwap0P[auctionId]).div(1 ether);
        if (_sellAmounts > 0) {
            if (auction._biddingToken == address(0)) {
                uint256 txFee = _sellAmounts.mul(getTxFeeRatio()).div(1 ether);
                uint256 _actual_sellAmounts = _sellAmounts.sub(txFee);
                if (_actual_sellAmounts > 0) {
                    auction.creator.transfer(_actual_sellAmounts);
                }
                if (txFee > 0) {
                    // deposit transaction fee to staking contract
                    IAnnexStake(getStakeContract()).depositReward{value: txFee}();
                }
            } else {
                IERC20(auction._biddingToken).safeTransfer(auction.creator, _sellAmounts);
            }
        }

        emit Claimed(auctionId, creator, unFilled_minBuyAmounts);
    }

    function bidderClaim(uint auctionId) external
        nonReentrant
        isAuctionExist(auctionId)
        isAuctionClosed(auctionId)
    {
        address payable bidder = msg.sender;
        require(!bidderClaimedP[bidder][auctionId], "bidder has claimed this auction");
        bidderClaimedP[bidder][auctionId] = true;

        Auction memory auction = auctions[auctionId];
        // send _auctioningToken to bidder
        if (myAmountSwap0P[bidder][auctionId] > 0) {
            IERC20(auction._auctioningToken).safeTransfer(bidder, myAmountSwap0P[bidder][auctionId]);
        }

        // send unfilled _biddingToken to bidder
        uint actual_sellAmounts = lowestBidPrice[auctionId].mul(myAmountSwap0P[bidder][auctionId]).div(1 ether);
        uint unfilled_sellAmounts = myAmountSwap1P[bidder][auctionId].sub(actual_sellAmounts);
        if (unfilled_sellAmounts > 0) {
            if (auction._biddingToken == address(0)) {
                bidder.transfer(unfilled_sellAmounts);
            } else {
                IERC20(auction._biddingToken).safeTransfer(bidder, unfilled_sellAmounts);
            }
        }
    }

    function _swap(address payable sender, uint auctionId, uint _minBuyAmounts, uint _sellAmounts) private {
        Auction memory auction = auctions[auctionId];
        uint __minBuyAmounts = auction._auctionedSellAmount.sub(amountSwap0P[auctionId]);
        uint __sellAmounts = 0;
        uint _excess_sellAmounts = 0;

        // check if _minBuyAmounts is exceeded
        if (__minBuyAmounts < _minBuyAmounts) {
            __sellAmounts = __minBuyAmounts.mul(_sellAmounts).div(_minBuyAmounts);
            _excess_sellAmounts = _sellAmounts.sub(__sellAmounts);
        } else {
            __minBuyAmounts = _minBuyAmounts;
            __sellAmounts = _sellAmounts;
        }
        myAmountSwap0P[sender][auctionId] = myAmountSwap0P[sender][auctionId].add(__minBuyAmounts);
        myAmountSwap1P[sender][auctionId] = myAmountSwap1P[sender][auctionId].add(__sellAmounts);
        amountSwap0P[auctionId] = amountSwap0P[auctionId].add(__minBuyAmounts);
        amountSwap1P[auctionId] = amountSwap1P[auctionId].add(__sellAmounts);

        // send excess amount of _biddingToken back to sender
        if (_excess_sellAmounts > 0) {
            if (auction._biddingToken == address(0)) {
                sender.transfer(_excess_sellAmounts);
            } else {
                IERC20(auction._biddingToken).safeTransfer(sender, _excess_sellAmounts);
            }
        }
    }

    function isCreator(address target, uint auctionId) private view returns (bool) {
        if (auctions[auctionId].creator == target) {
            return true;
        }
        return false;
    }

    function currentPrice(uint auctionId) public view returns (uint) {
        Auction memory auction = auctions[auctionId];
        uint __sellAmounts = auction.amountMin1;
        uint realTimes = auction.times.add(1);

        if (now < auction.auctionEndDate) {
            uint stepInSeconds = auction.duration.div(realTimes);
            if (stepInSeconds != 0) {
                uint remainingTimes = auction.auctionEndDate.sub(now).sub(1).div(stepInSeconds);
                if (remainingTimes != 0) {
                    __sellAmounts = auction.amountMax1.sub(auction.amountMin1)
                        .mul(remainingTimes).div(auction.times)
                        .add(auction.amountMin1);
                }
            }
        }

        return __sellAmounts.mul(1 ether).div(auction._auctionedSellAmount);
    }

    function nextRoundInSeconds(uint auctionId) public view returns (uint) {
        Auction memory auction = auctions[auctionId];
        if (now >= auction.auctionEndDate) return 0;
        uint realTimes = auction.times.add(1);
        uint stepInSeconds = auction.duration.div(realTimes);
        if (stepInSeconds == 0) return 0;
        uint remainingTimes = auction.auctionEndDate.sub(now).sub(1).div(stepInSeconds);

        return auction.auctionEndDate.sub(remainingTimes.mul(stepInSeconds)).sub(now);
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

    modifier checkBotHolder(uint auctionId) {
        if (onlyBotHolderP[auctionId]) {
            require(IERC20(getBotToken()).balanceOf(msg.sender) >= getMinValueOfBotHolder(), "BOT is not enough");
        }
        _;
    }

    modifier isAuctionClosed(uint auctionId) {
        require(auctions[auctionId].auctionEndDate <= now, "this auction is not closed");
        _;
    }

    modifier isAuctionNotClosed(uint auctionId) {
        require(auctions[auctionId].auctionEndDate > now, "this auction is closed");
        _;
    }

    modifier isAuctionNotCreate(address target) {
        if (myCreatedP[target] > 0) {
            revert("a auction has created by this address");
        }
        _;
    }

    modifier isAuctionExist(uint auctionId) {
        require(auctionId < auctions.length, "this auction does not exist");
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