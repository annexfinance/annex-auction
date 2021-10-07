// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
// import "./Access/Governable.sol";
import "./interfaces/IDocuments.sol";
import "./interfaces/IAnnexStake.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract AnnexDutchAuction is ReentrancyGuard, Ownable {
    IDocuments public documents; // for storing documents
    IERC20 public annexToken;
    address public treasury;
    uint256 public threshold = 100000 ether; // 100000 ANN
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address;
    bytes32 internal constant TxFeeRatio = bytes32("TxFeeRatio");
    bytes32 internal constant MinValueOfBotHolder =
        bytes32("MinValueOfBotHolder");
    bytes32 internal constant BotToken = bytes32("BotToken");
    bytes32 internal constant StakeContract = bytes32("StakeContract");
    struct AuctionReq {
        // string name;
        // address payable creator;
        address _auctioningToken;
        address _biddingToken;
        uint256 _auctionedSellAmount;
        uint256 amountMax1;
        uint256 amountMin1;
        uint256 times;
        uint256 auctionStartDate;
        uint256 auctionEndDate;
        bool onlyBot;
        bool enableWhiteList;
        AuctionAbout about;
    }
    struct AuctionData {
        // string name;
        address payable creator;
        address _auctioningToken;
        address _biddingToken;
        uint256 _auctionedSellAmount;
        uint256 amountMax1;
        uint256 amountMin1;
        uint256 times;
        uint256 duration;
        uint256 auctionStartDate;
        uint256 auctionEndDate;
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
    AuctionData[] public auctions;
    mapping(uint256 => uint256) public amountSwap0P;
    mapping(uint256 => uint256) public amountSwap1P;
    mapping(uint256 => bool) public creatorClaimedP;
    mapping(uint256 => bool) public onlyBotHolderP;
    mapping(uint256 => uint256) public lowestBidPrice;
    mapping(address => mapping(uint256 => bool)) public bidderClaimedP;
    mapping(address => mapping(uint256 => uint256)) public myAmountSwap0P;
    mapping(address => mapping(uint256 => uint256)) public myAmountSwap1P;
    mapping(address => uint256) public myCreatedP;
    bool public enableWhiteList;
    mapping(uint256 => mapping(address => bool)) public whitelistP;
    event Created(uint256 indexed auctionId, address indexed sender, AuctionData auction);
    event Bid(
        uint256 indexed auctionId,
        address indexed sender,
        uint256 amount0,
        uint256 amount1
    );
    event Claimed(
        uint256 indexed auctionId,
        address indexed sender,
        uint256 unFilledAmount0
    );
    event AuctionDetails(
        uint256 indexed auctionId,
        string[6] social
    );
    // function initialize() public initializer {
 
    //     config[TxFeeRatio] = 0.005 ether; // 0.5%
    //     config[MinValueOfBotHolder] = 60 ether;
    //     config[BotToken] = uint256(uint160(0xA9B1Eb5908CfC3cdf91F9B8B3a74108598009096)); // AUCTION
    //     config[StakeContract] = uint256(
    //         uint160(0x98945BC69A554F8b129b09aC8AfDc2cc2431c48E)
    //     );
    // }
    // function initialize_rinkeby() public {
    //     initialize();
    //     config[BotToken] = uint256(uint160(0x5E26FA0FE067d28aae8aFf2fB85Ac2E693BD9EfA)); // AUCTION
    //     config[StakeContract] = uint256(
    //         uint160(0xa77A9FcbA2Ae5599e0054369d1655D186020ECE1)
    //     );
    // }
    // function initialize_bsc() public {
    //     initialize();
    //     config[BotToken] = uint256(uint160(0x1188d953aFC697C031851169EEf640F23ac8529C)); // AUCTION
    //     config[StakeContract] = uint256(
    //         uint160(0x1dd665ba1591756aa87157F082F175bDcA9fB91a)
    //     );
    // }
    function initiateAuction(AuctionReq memory auctionReq, address[] memory whitelist_)
        external
        nonReentrant
    {
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
        require(auctionReq.amountMax1 > auctionReq.amountMin1,"amountMax1 should larger than amountMin1");
        // require(auctionReq.auctionStartDate <= auctionReq.auctionEndDate && auctionReq.auctionEndDate.sub(auctionReq.auctionStartDate) < 7 days, "invalid closed");
        require(auctionReq.times != 0, "the value of times is zero");
        // require(bytes(auctionReq.name).length <= 15,"the length of name is too long");
        uint256 auctionId = auctions.length;
        IERC20 __auctioningToken = IERC20(auctionReq._auctioningToken);
        uint256 _auctioningTokenBalanceBefore = __auctioningToken.balanceOf(address(this));
        __auctioningToken.safeTransferFrom(msg.sender,address(this),auctionReq._auctionedSellAmount);
        require(__auctioningToken.balanceOf(address(this)).sub(_auctioningTokenBalanceBefore) == auctionReq._auctionedSellAmount,"not support deflationary token");
        if (auctionReq.enableWhiteList) {
            require(whitelist_.length > 0, "no whitelist imported");
            _addWhitelist(auctionId, whitelist_);
        }
        AuctionData memory auction;
        // auction.name = auctionReq.name;
        auction.creator = msg.sender;
        auction._auctioningToken = auctionReq._auctioningToken;
        auction._biddingToken = auctionReq._biddingToken;
        auction._auctionedSellAmount = auctionReq._auctionedSellAmount;
        auction.amountMax1 = auctionReq.amountMax1;
        auction.amountMin1 = auctionReq.amountMin1;
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

        string[6] memory socials = [auctionReq.about.website,auctionReq.about.description,auctionReq.about.telegram,auctionReq.about.discord,auctionReq.about.medium,auctionReq.about.twitter];
        emit AuctionDetails(
            auctionId,
            socials
        );
    }
    function placeSellOrders(
        uint256 auctionId,
        uint256 amount0,
        uint256 amount1
    )
        external
        payable
        nonReentrant
        isAuctionExist(auctionId)
        // checkBotHolder(auctionId)
        isAuctionNotClosed(auctionId)
    {
        address payable sender = payable(msg.sender) ;
        require(tx.origin == msg.sender, "disallow contract caller");
        if (enableWhiteList) {
            require(whitelistP[auctionId][sender], "sender not in whitelist");
        }
        AuctionData memory auction = auctions[auctionId];
        require(auction.auctionStartDate <= block.timestamp , "auction not open");
        require(amount0 != 0, "the value of amount0 is zero");
        require(amount1 != 0, "the value of amount1 is zero");
        require(auction._auctionedSellAmount > amountSwap0P[auctionId], "swap amount is zero");
        uint256 curPrice = currentPrice(auctionId);
        uint256 bidPrice = amount1.mul(1 ether).div(amount0);
        require(
            bidPrice >= curPrice,
            "the bid price is lower than the current price"
        );
        if (lowestBidPrice[auctionId] == 0 || lowestBidPrice[auctionId] > bidPrice) {
            lowestBidPrice[auctionId] = bidPrice;
        }
        address _biddingToken = auction._biddingToken;
        if (_biddingToken == address(0)) {
            require(amount1 == msg.value, "invalid ETH amount");
        } else {
            IERC20(_biddingToken).safeTransferFrom(sender, address(this), amount1);
        }
        _swap(sender, auctionId, amount0, amount1);
        emit Bid(auctionId, sender, amount0, amount1);
    }
    function creatorClaim(uint256 auctionId)
        external
        nonReentrant
        isAuctionExist(auctionId)
        isAuctionClosed(auctionId)
    {
        address payable creator = payable(msg.sender);
        require(isCreator(creator, auctionId), "sender is not auction creator");
        require(!creatorClaimedP[auctionId], "creator has claimed this auction");
        creatorClaimedP[auctionId] = true;
        delete myCreatedP[creator];
        AuctionData memory auction = auctions[auctionId];
        uint256 unFilledAmount0 = auction._auctionedSellAmount.sub(amountSwap0P[auctionId]);
        if (unFilledAmount0 > 0) {
            IERC20(auction._auctioningToken).safeTransfer(creator, unFilledAmount0);
        }
        uint256 amount1 = lowestBidPrice[auctionId].mul(amountSwap0P[auctionId]).div(
            1 ether
        );
        if (amount1 > 0) {
            if (auction._biddingToken == address(0)) {
                // uint256 txFee = amount1.mul(getTxFeeRatio()).div(1 ether);
                uint256 _actualAmount1 = amount1.sub(txFee);
                if (_actualAmount1 > 0) {
                    auction.creator.transfer(_actualAmount1);
                }
                // if (txFee > 0) {
                //     IAnnexStake(getStakeContract()).depositReward{
                //         value: txFee
                //     }();
                // }
            } else {
                IERC20(auction._biddingToken).safeTransfer(auction.creator, amount1);
            }
        }
        emit Claimed(auctionId, creator, unFilledAmount0);
    }
    function bidderClaim(uint256 auctionId)
        external
        nonReentrant
        isAuctionExist(auctionId)
        isAuctionClosed(auctionId)
    {
        address payable bidder = payable(msg.sender);
        require(!bidderClaimedP[bidder][auctionId], "bidder has claimed this auction");
        bidderClaimedP[bidder][auctionId] = true;
        AuctionData memory auction = auctions[auctionId];
        if (myAmountSwap0P[bidder][auctionId] > 0) {
            IERC20(auction._auctioningToken).safeTransfer(
                bidder,
                myAmountSwap0P[bidder][auctionId]
            );
        }
        uint256 actualAmount1 = lowestBidPrice[auctionId]
            .mul(myAmountSwap0P[bidder][auctionId])
            .div(1 ether);
        uint256 unfilledAmount1 = myAmountSwap1P[bidder][auctionId].sub(
            actualAmount1
        );
        if (unfilledAmount1 > 0) {
            if (auction._biddingToken == address(0)) {
                bidder.transfer(unfilledAmount1);
            } else {
                IERC20(auction._biddingToken).safeTransfer(bidder, unfilledAmount1);
            }
        }
    }
    function _swap(
        address payable sender,
        uint256 auctionId,
        uint256 amount0,
        uint256 amount1
    ) private {
        AuctionData memory auction = auctions[auctionId];
        uint256 _amount0 = auction._auctionedSellAmount.sub(amountSwap0P[auctionId]);
        uint256 _amount1 = 0;
        uint256 _excessAmount1 = 0;
        if (_amount0 < amount0) {
            _amount1 = _amount0.mul(amount1).div(amount0);
            _excessAmount1 = amount1.sub(_amount1);
        } else {
            _amount0 = amount0;
            _amount1 = amount1;
        }
        myAmountSwap0P[sender][auctionId] = myAmountSwap0P[sender][auctionId].add(
            _amount0
        );
        myAmountSwap1P[sender][auctionId] = myAmountSwap1P[sender][auctionId].add(
            _amount1
        );
        amountSwap0P[auctionId] = amountSwap0P[auctionId].add(_amount0);
        amountSwap1P[auctionId] = amountSwap1P[auctionId].add(_amount1);
        if (_excessAmount1 > 0) {
            if (auction._biddingToken == address(0)) {
                sender.transfer(_excessAmount1);
            } else {
                IERC20(auction._biddingToken).safeTransfer(sender, _excessAmount1);
            }
        }
    }
    function isCreator(address target, uint256 auctionId)
        private
        view
        returns (bool)
    {
        if (auctions[auctionId].creator == target) {
            return true;
        }
        return false;
    }
    function currentPrice(uint256 auctionId) public view returns (uint256) {
        AuctionData memory auction = auctions[auctionId];
        uint256 _amount1 = auction.amountMin1;
        uint256 realTimes = auction.times.add(1);
        if (block.timestamp < auction.auctionEndDate) {
            uint256 stepInSeconds = auction.duration.div(realTimes);
            if (stepInSeconds != 0) {
                uint256 remainingTimes = auction.auctionEndDate.sub(block.timestamp).sub(1).div(
                    stepInSeconds
                );
                if (remainingTimes != 0) {
                    _amount1 = auction
                        .amountMax1
                        .sub(auction.amountMin1)
                        .mul(remainingTimes)
                        .div(auction.times)
                        .add(auction.amountMin1);
                }
            }
        }
        return _amount1.mul(1 ether).div(auction._auctionedSellAmount);
    }
    function nextRoundInSeconds(uint256 auctionId) public view returns (uint256) {
        AuctionData memory auction = auctions[auctionId];
        if (block.timestamp >= auction.auctionEndDate) return 0;
        uint256 realTimes = auction.times.add(1);
        uint256 stepInSeconds = auction.duration.div(realTimes);
        if (stepInSeconds == 0) return 0;
        uint256 remainingTimes = auction.auctionEndDate.sub(block.timestamp).sub(1).div(
            stepInSeconds
        );
        return auction.auctionEndDate.sub(remainingTimes.mul(stepInSeconds)).sub(block.timestamp);
    }
    function _addWhitelist(uint256 auctionId, address[] memory whitelist_) private {
        for (uint256 i = 0; i < whitelist_.length; i++) {
            whitelistP[auctionId][whitelist_[i]] = true;
        }
    }
    function addWhitelist(uint256 auctionId, address[] memory whitelist_) external {
        require(
            owner() == msg.sender || auctions[auctionId].creator == msg.sender,
            "no permission"
        );
        _addWhitelist(auctionId, whitelist_);
    }
    function removeWhitelist(uint256 auctionId, address[] memory whitelist_)
        external
    {
        require(
            owner() == msg.sender || auctions[auctionId].creator == msg.sender,
            "no permission"
        );
        for (uint256 i = 0; i < whitelist_.length; i++) {
            delete whitelistP[auctionId][whitelist_[i]];
        }
    }
    function getAuctionCount() public view returns (uint256) {
        return auctions.length;
    }
    // function getTxFeeRatio() public view returns (uint256) {
    //     return config[TxFeeRatio];
    // }
    // function getMinValueOfBotHolder() public view returns (uint256) {
    //     return config[MinValueOfBotHolder];
    // }
    // function getBotToken() public view returns (address) {
    //     return address(uint160(config[BotToken]));
    // }
    // function getStakeContract() public view returns (address) {
    //     return address(uint160(config[StakeContract]));
    // }
    // modifier checkBotHolder(uint256 auctionId) {
    //     if (onlyBotHolderP[auctionId]) {
    //         require(
    //             IERC20(getBotToken()).balanceOf(msg.sender) >=
    //                 getMinValueOfBotHolder(),
    //             "BOT is not enough"
    //         );
    //     }
    //     _;
    // }
    modifier isAuctionClosed(uint256 auctionId) {
        require(auctions[auctionId].auctionEndDate <= block.timestamp, "this auction is not closed");
        _;
    }
    modifier isAuctionNotClosed(uint256 auctionId) {
        require(auctions[auctionId].auctionEndDate > block.timestamp, "this auction is closed");
        _;
    }
    modifier isAuctionNotCreate(address target) {
        if (myCreatedP[target] > 0) {
            revert("a auction has created by this address");
        }
        _;
    }
    modifier isAuctionExist(uint256 auctionId) {
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
}