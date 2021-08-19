// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "./libraries/IterableOrderedOrderSet.sol";
import "./interfaces/AllowListVerifier.sol";
import "./libraries/IdToAddressBiMap.sol";
import "./libraries/SafeCast.sol";
import "./interfaces/IDocuments.sol";
import "./interfaces/IPancakeswapV2Pair.sol";
import "./interfaces/IPancakeswapV2Factory.sol";
import "./interfaces/IPancakeswapV2Router02.sol";

// import "hardhat/console.sol";
/**
Errors details
    ERROR_ORDER_PLACEMENT = no longer in order placement phase
    ERROR_ORDER_CANCELATION = no longer in order placement and cancelation phase
    ERROR_SOL_SUB = Auction not in solution submission phase
    ERROR_NOT_FINSIHED = Auction not yet finished
    ERROR_INVALID_FEE = Fee is not allowed to be set higher than 1.5%
    ERROR_MUST_GT_ZERO = _minBuyAmounts must be greater than 0
    NOT_ENOUGH_ANN = Auctioner does not have enough Ann
    TOO_SMALL = order too small
    INVALID_AUCTION_TOKENS = cannot auction zero tokens and must be less than threshold
    TOKENS_CANT_AUCTIONED_FREE = tokens cannot be auctioned for free
    MUST_NOT_ZERO = minimumBiddingAmountPerOrder is not allowed to be zero
    ERROR_TIME_PERIOD = time periods are not configured correctly
    INVALID_AUTION_END = auction end date must be in the future
    ONLY_USER_CAN_CANCEL = Only the user can cancel his orders
    REACHED_END = reached end of order list
    TOO_MANY_ORDERS = too many orders summed up
    NOT_SETTLED = not allowed to settle auction atomically 
    ERROR_PALCE_AUTOMATICALLY = Only one order can be placed atomically
    TOO_ADVANCED = precalculateSellAmountSum is already too advanced
    REGISTERED = User already registered
    NOT_ALLOWED= user not allowed to place order
    INVALID_LIMIT_PRICE = limit price not better than mimimal offer
    NOT_CLAIMABLE = order is no longer claimable
    SAME_USER_CAN_CLAIM= only allowed to claim for same user
    PENDING_PHASE = not started yet
    INVALID_AUCTION_START = invalid start date
**/

contract AnnexBatchAuction is Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint64;
    using SafeMath for uint96;
    using SafeMath for uint256;
    using SafeCast for uint256;
    using IterableOrderedOrderSet for IterableOrderedOrderSet.Data;
    using IterableOrderedOrderSet for bytes32;
    using IdToAddressBiMap for IdToAddressBiMap.Data;

    struct AuctionAbout {
        string website;
        string description;
        string telegram;
        string discord;
        string medium;
        string twitter;
    }

    struct AuctionReq {
        IERC20 _auctioningToken;
        IERC20 _biddingToken;
        address accessManagerContract;
        uint256 orderCancellationEndDate;
        uint256 auctionStartDate;
        uint256 auctionEndDate;
        uint256 minimumBiddingAmountPerOrder;
        uint256 minFundingThreshold;
        uint96 _auctionedSellAmount;
        uint96 _minBuyAmount;
        bool isAtomicClosureAllowed;
        bytes accessManagerContractData;
        uint8 router;
        AuctionAbout about;
    }

    struct AuctionData {
        // address of bidding token
        IERC20 auctioningToken;
        // address of auctioning token
        IERC20 biddingToken;
        // This will be the date after which the bidder cannot cancel his orders.
        uint256 orderCancellationEndDate;
        // auction end date at which auction will end
        uint256 auctionEndDate;
        // This will be the minimum amount of bidding tokens a bidder can bid
        uint256 minimumBiddingAmountPerOrder;
        // this will be the sum of bid amount during precalculateSellAmountSum()
        uint256 interimSumBidAmount;
        // auction fee for auctioneer
        uint256 feeNumerator;
        // this will be the minimum funding threshold of bidding tokens that auctioneer
        // wants in return of auctioning tokens.
        uint256 minFundingThreshold;
        // This will be the initial order during auction creation which will be consist of
        // minimum buy amount against all auctioned tokens and total auctioned tokens by auctioneer
        bytes32 initialAuctionOrder;
        // The last viewed order during precalculateSellAmountSum function.
        bytes32 interimOrder;
        // The last order at which auction will be concluded will be the clearingPriceOrder
        // bytes32 clearingPriceOrder;
        uint96 volumeClearingPriceOrder;
        // flag to check either auction get reached minimum funding threshold or not
        bool minFundingThresholdNotReached;
        // flag for automatically auction settlement
        bool isAtomicClosureAllowed;
    }

    mapping(uint256 => IterableOrderedOrderSet.Data) internal sellOrders; // Store total number of sell orders
    mapping(uint256 => AuctionData) public auctionData; // Store auctions details
    mapping(uint256 => address) public auctionAccessManager;
    mapping(uint256 => bytes) public auctionAccessData;
    // auctionId => order bytes
    mapping(uint256 => bytes32) public clearingPriceOrders; // clearing price orders
    // auctionId => starting date
    mapping(uint256 => uint256) public startingDate; // starting date
    // auctionId => IPancakeswapV2Pair (liquidity pool)
    //address of pancakeswap liquidity pools of pairs auctioningToken-biddingToken
    mapping(uint256 => address) public liquidityPools;
    mapping(uint256 => uint256) public poolLiquidities;
    // auctionId => pancakeswapV2Router address
    mapping(uint256 => address) public pancakeswapV2Router;
    // address for PancakeswapV2Router02
    address[] public routers;

    IDocuments public documents; // for storing documents
    IERC20 public annexToken;
    address public treasury;

    IdToAddressBiMap.Data private registeredUsers;
    uint256 public auctionCounter; // counter for auctions
    uint256 public feeNumerator = 0;
    uint256 public constant FEE_DENOMINATOR = 1000;
    uint256 public threshold = 100 ether; // 100 ANN

    uint64 public feeReceiverUserId = 1;
    uint64 public numUsers; // counter of users

    modifier atStageOrderPlacement(uint256 auctionId) {
        require(
            block.timestamp > startingDate[auctionId],
            "ERROR_NOT_STARTED" // not started yet
        );
        require(
            block.timestamp < auctionData[auctionId].auctionEndDate,
            "ERROR_ORDER_PLACEMENT" // no longer in order placement phase
        );
        _;
    }

    modifier atStageOrderPlacementAndCancelation(uint256 auctionId) {
        require(
            block.timestamp < auctionData[auctionId].orderCancellationEndDate,
            "ERROR_ORDER_CANCELATION"
        );
        _;
    }

    modifier atStageSolutionSubmission(uint256 auctionId) {
        {
            uint256 auctionEndDate = auctionData[auctionId].auctionEndDate;
            require(
                auctionEndDate != 0 &&
                    block.timestamp >= auctionEndDate &&
                    clearingPriceOrders[auctionId] == bytes32(0),
                "ERROR_SOL_SUB"
            );
        }
        _;
    }

    modifier atStageFinished(uint256 auctionId) {
        require(
            clearingPriceOrders[auctionId] != bytes32(0),
            "ERROR_NOT_FINSIHED"
        );
        _;
    }

    event NewSellOrder(
        uint256 indexed auctionId,
        uint64 indexed userId,
        uint96 buyAmount,
        uint96 sellAmount
    );
    event CancellationSellOrder(
        uint256 indexed auctionId,
        uint64 indexed userId,
        uint96 buyAmount,
        uint96 sellAmount
    );
    event ClaimedFromOrder(
        uint256 indexed auctionId,
        uint64 indexed userId,
        uint96 buyAmount,
        uint96 sellAmount
    );
    event ClaimedLPFromOrder(
        uint256 indexed auctionId,
        uint64 userId,
        uint256 sumBiddingTokenAmount,
        uint256 lps
    );

    event NewUser(uint64 indexed userId, address indexed userAddress);
    event NewAuction(
        uint256 indexed auctionId,
        IERC20 indexed _auctioningToken,
        IERC20 indexed _biddingToken,
        uint256 orderCancellationEndDate,
        uint256 auctionStartDate,
        uint256 auctionEndDate,
        uint64 userId,
        uint96 _auctionedSellAmount,
        uint96 _minBuyAmount,
        uint256 minimumBiddingAmountPerOrder
    );
    event AuctionCleared(
        uint256 indexed auctionId,
        uint96 soldAuctioningTokens,
        uint96 soldBiddingTokens,
        bytes32 clearingPriceOrder
    );
    event UserRegistration(address indexed user, uint64 userId);
    event AddRouters(address[] indexed routers);
    event AddLiquidity(uint256 indexed auctionId, uint256 liquidity);

    event CalculatedLP(
        uint256 indexed auctionId,
        uint256 biddingTokenAmount,
        uint256 totalBiddingTokenAmount,
        uint256 totalLP
    );

    event Bidder(
        uint256 indexed auctionId,
        uint96 buyAmount,
        uint96 sellAmount,
        uint64 userId,
        string status
    );

    event AuctionDetails(
        uint256 indexed auctionId,
        string[6] social
    );

    constructor() public {}

    function setFeeParameters(
        uint256 newFeeNumerator,
        address newfeeReceiverAddress
    ) public onlyOwner() {
        require(
            newFeeNumerator <= 15,
            "ERROR_INVALID_FEE" // Fee is not allowed to be set higher than 1.5%
        );
        // caution: for currently running auctions, the feeReceiverUserId is changing as well.
        feeReceiverUserId = getUserId(newfeeReceiverAddress);
        feeNumerator = newFeeNumerator;
    }

    // @dev: function to intiate a new auction
    // Warning: In case the auction is expected to raise more than
    // 2^96 units of the biddingToken, don't start the auction, as
    // it will not be settlable. This corresponds to about 79
    // billion DAI.
    //
    // Prices between biddingToken and auctioningToken are expressed by a
    // fraction whose components are stored as uint96.
    // Amount transfered out is no larger than amount transfered in
    // auctioning Token = USDT
    // bidding Token    = ANN
    // pair             = USDT-ANN

    function initiateAuction(AuctionReq calldata auction)
        public
        returns (uint256)
    {
        // Auctioner can init an auction if he has 100 Ann
        require(
            annexToken.balanceOf(msg.sender) >= threshold,
            "NOT_ENOUGH_ANN"
        );
        annexToken.safeTransferFrom(msg.sender, treasury, 100 ether);
        auction._auctioningToken.safeTransferFrom(
            msg.sender,
            address(this),
            auction
                ._auctionedSellAmount
                .mul(FEE_DENOMINATOR.add(feeNumerator))
                .div(FEE_DENOMINATOR) //[0]
        );
        require(auction._auctionedSellAmount > 0, "INVALID_AUCTION_TOKENS"); //
        require(auction._minBuyAmount > 0, "TOKENS_CANT_AUCTIONED_FREE"); // tokens cannot be auctioned for free
        require(auction.minimumBiddingAmountPerOrder > 0, "MUST_NOT_ZERO");
        require(
            auction.orderCancellationEndDate <= auction.auctionEndDate,
            "ERROR_TIME_PERIOD"
        );
        // require(auction.auctionStartDate > block.timestamp && auction.auctionStartDate < auction.auctionEndDate , "INVALID_AUCTION_START");
        require(auction.auctionEndDate > block.timestamp, "INVALID_AUCTION_END");
        auctionCounter = auctionCounter.add(1);
        sellOrders[auctionCounter].initializeEmptyList();
        uint64 userId = getUserId(msg.sender);

        {
            auctionData[auctionCounter] = AuctionData(
                auction._auctioningToken,
                auction._biddingToken,
                auction.orderCancellationEndDate,
                auction.auctionEndDate,
                auction.minimumBiddingAmountPerOrder,
                0,
                feeNumerator,
                auction.minFundingThreshold,
                IterableOrderedOrderSet.encodeOrder(
                    userId,
                    auction._minBuyAmount,
                    auction._auctionedSellAmount
                ),
                IterableOrderedOrderSet.QUEUE_START,
                0,
                false,
                auction.isAtomicClosureAllowed
            );
            pancakeswapV2Router[auctionCounter] = routers[auction.router];

            startingDate[auctionCounter] = auction.auctionStartDate;
            auctionAccessManager[auctionCounter] = auction
            .accessManagerContract;
            auctionAccessData[auctionCounter] = auction
            .accessManagerContractData;
        }

        emit NewAuction(
            auctionCounter,
            auction._auctioningToken,
            auction._biddingToken,
            auction.orderCancellationEndDate,
            auction.auctionStartDate,
            auction.auctionEndDate,
            userId,
            auction._auctionedSellAmount,
            auction._minBuyAmount,
            auction.minimumBiddingAmountPerOrder
        );
        /**
        * socials[0] = webiste link 
        * socials[1] = description 
        * socials[2] = telegram link 
        * socials[3] = discord link 
        * socials[4] = medium link 
        * socials[5] = twitter link 
        **/
        string[6] memory socials = [auction.about.website,auction.about.description,auction.about.telegram,auction.about.discord,auction.about.medium,auction.about.twitter];
        emit AuctionDetails(
            auctionCounter,
            socials
        );
        return auctionCounter;
    }

    function placeSellOrders(
        uint256 auctionId,
        uint96[] memory _minBuyAmounts,
        uint96[] memory _sellAmounts,
        bytes32[] memory _prevSellOrders,
        bytes calldata allowListCallData
    ) external atStageOrderPlacement(auctionId) returns (uint64 userId) {
        return
            _placeSellOrders(
                auctionId,
                _minBuyAmounts,
                _sellAmounts,
                _prevSellOrders,
                allowListCallData,
                msg.sender
            );
    }

    function placeSellOrdersOnBehalf(
        uint256 auctionId,
        uint96[] memory _minBuyAmounts,
        uint96[] memory _sellAmounts,
        bytes32[] memory _prevSellOrders,
        bytes calldata allowListCallData,
        address orderSubmitter
    ) external atStageOrderPlacement(auctionId) returns (uint64 userId) {
        return
            _placeSellOrders(
                auctionId,
                _minBuyAmounts,
                _sellAmounts,
                _prevSellOrders,
                allowListCallData,
                orderSubmitter
            );
    }

    function _placeSellOrders(
        uint256 auctionId,
        uint96[] memory _minBuyAmounts,
        uint96[] memory _sellAmounts,
        bytes32[] memory _prevSellOrders,
        bytes calldata allowListCallData,
        address orderSubmitter
    ) internal returns (uint64 userId) {
        {
            address allowListManager = auctionAccessManager[auctionId];
            if (allowListManager != address(0)) {
                require(
                    AllowListVerifier(allowListManager).isAllowed(
                        orderSubmitter,
                        auctionId,
                        allowListCallData
                    ) == AllowListVerifierHelper.MAGICVALUE,
                    "NOT_ALLOWED"
                );
            }
        }
        {
            (
                ,
                uint96 buyAmountOfInitialAuctionOrder,
                uint96 sellAmountOfInitialAuctionOrder
            ) = auctionData[auctionId].initialAuctionOrder.decodeOrder();
            for (uint256 i = 0; i < _minBuyAmounts.length; i++) {
                require(
                    _minBuyAmounts[i].mul(buyAmountOfInitialAuctionOrder) <
                        sellAmountOfInitialAuctionOrder.mul(_sellAmounts[i]),
                    "INVALID_LIMIT_PRICE"
                );
            }
        }
        uint256 sumOfSellAmounts = 0;
        userId = getUserId(orderSubmitter);
        uint256 minimumBiddingAmountPerOrder = auctionData[auctionId]
        .minimumBiddingAmountPerOrder;
        for (uint256 i = 0; i < _minBuyAmounts.length; i++) {
            require(
                _minBuyAmounts[i] > 0,
                "ERROR_MUST_GT_ZERO" //_minBuyAmounts must be greater than 0
            );
            // orders should have a minimum bid size in order to limit the gas
            // required to compute the final price of the auction.
            require(
                _sellAmounts[i] > minimumBiddingAmountPerOrder,
                "TOO_SMALL" // order too small
            );
            if (
                sellOrders[auctionId].insert(
                    IterableOrderedOrderSet.encodeOrder(
                        userId,
                        _minBuyAmounts[i],
                        _sellAmounts[i]
                    ),
                    _prevSellOrders[i]
                )
            ) {
                sumOfSellAmounts = sumOfSellAmounts.add(_sellAmounts[i]);
                emit NewSellOrder(
                    auctionId,
                    userId,
                    _minBuyAmounts[i],
                    _sellAmounts[i]
                );
            }
        }

        auctionData[auctionId].biddingToken.safeTransferFrom(
            msg.sender,
            address(this),
            sumOfSellAmounts
        ); //[1]
    }

    function cancelSellOrders(uint256 auctionId, bytes32[] memory _sellOrders)
        public
        atStageOrderPlacementAndCancelation(auctionId)
    {
        uint64 userId = getUserId(msg.sender);
        uint256 claimableAmount = 0;
        for (uint256 i = 0; i < _sellOrders.length; i++) {
            // Note: we keep the back pointer of the deleted element so that
            // it can be used as a reference point to insert a new node.
            bool success = sellOrders[auctionId].removeKeepHistory(
                _sellOrders[i]
            );
            if (success) {
                (
                    uint64 userIdOfIter,
                    uint96 buyAmountOfIter,
                    uint96 sellAmountOfIter
                ) = _sellOrders[i].decodeOrder();
                require(
                    userIdOfIter == userId,
                    "ONLY_USER_CAN_CANCEL" // Only the user can cancel his orders
                );
                claimableAmount = claimableAmount.add(sellAmountOfIter);
                emit CancellationSellOrder(
                    auctionId,
                    userId,
                    buyAmountOfIter,
                    sellAmountOfIter
                );
            }
        }
        auctionData[auctionId].biddingToken.safeTransfer(
            msg.sender,
            claimableAmount
        ); //[2]
    }

    // @note this function should be called before settling the acution
    // By calling this function you can pre calculate(before auction ending) sum of total
    // total token sold.This function will calculate sum by taking offsent of orders linked list.
    function precalculateSellAmountSum(
        uint256 auctionId,
        uint256 iterationSteps
    ) public atStageSolutionSubmission(auctionId) {
        (, , uint96 auctioneerSellAmount) = auctionData[auctionId]
        .initialAuctionOrder
        .decodeOrder();
        uint256 sumBidAmount = auctionData[auctionId].interimSumBidAmount;
        bytes32 iterOrder = auctionData[auctionId].interimOrder;

        for (uint256 i = 0; i < iterationSteps; i++) {
            iterOrder = sellOrders[auctionId].next(iterOrder);
            (, , uint96 sellAmountOfIter) = iterOrder.decodeOrder();
            sumBidAmount = sumBidAmount.add(sellAmountOfIter);
        }

        require(
            iterOrder != IterableOrderedOrderSet.QUEUE_END,
            "REACHED_END" //reached end of order list
        );

        // it is checked that not too many iteration steps were taken:
        // require that the sum of SellAmounts times the price of the last order
        // is not more than initially sold amount
        (, uint96 buyAmountOfIter, uint96 sellAmountOfIter) = iterOrder
        .decodeOrder();
        require(
            sumBidAmount.mul(buyAmountOfIter) <
                auctioneerSellAmount.mul(sellAmountOfIter),
            "TOO_MANY_ORDERS" // too many orders summed up
        );

        auctionData[auctionId].interimSumBidAmount = sumBidAmount;
        auctionData[auctionId].interimOrder = iterOrder;
    }

    function settleAuctionAtomically(
        uint256 auctionId,
        uint96[] memory _minBuyAmount,
        uint96[] memory _sellAmount,
        bytes32[] memory _prevSellOrder,
        bytes calldata allowListCallData
    ) public atStageSolutionSubmission(auctionId) {
        require(
            auctionData[auctionId].isAtomicClosureAllowed,
            "NOT_SETTLED" // not allowed to settle auction atomically
        );
        require(
            _minBuyAmount.length == 1 && _sellAmount.length == 1,
            "ERROR_PALCE_AUTOMATICALLY" //Only one order can be placed atomically
        );
        uint64 userId = getUserId(msg.sender);
        require(
            auctionData[auctionId].interimOrder.smallerThan(
                IterableOrderedOrderSet.encodeOrder(
                    userId,
                    _minBuyAmount[0],
                    _sellAmount[0]
                )
            ),
            "TOO_ADVANCED" // precalculateSellAmountSum is already too advanced
        );
        _placeSellOrders(
            auctionId,
            _minBuyAmount,
            _sellAmount,
            _prevSellOrder,
            allowListCallData,
            msg.sender
        );
        settleAuction(auctionId);
    }

    // // @dev function settling the auction and calculating the price
    function settleAuction(uint256 auctionId)
        public
        atStageSolutionSubmission(auctionId)
        returns (bytes32 clearingOrder)
    {
        (
            uint64 auctioneerId,
            uint96 minAuctionedBuyAmount,
            uint96 fullAuctionedAmount
        ) = auctionData[auctionId].initialAuctionOrder.decodeOrder();

        uint256 currentBidSum = auctionData[auctionId].interimSumBidAmount;
        bytes32 currentOrder = auctionData[auctionId].interimOrder;
        uint256 buyAmountOfIter;
        uint256 sellAmountOfIter;
        uint96 fillVolumeOfAuctioneerOrder = fullAuctionedAmount;
        // Sum order up, until fullAuctionedAmount is fully bought or queue end is reached
        do {
            bytes32 nextOrder = sellOrders[auctionId].next(currentOrder);
            if (nextOrder == IterableOrderedOrderSet.QUEUE_END) {
                break;
            }
            currentOrder = nextOrder;
            (, buyAmountOfIter, sellAmountOfIter) = currentOrder.decodeOrder();
            currentBidSum = currentBidSum.add(sellAmountOfIter);
        } while (
            currentBidSum.mul(buyAmountOfIter) <
                fullAuctionedAmount.mul(sellAmountOfIter)
        );

        if (
            currentBidSum > 0 &&
            currentBidSum.mul(buyAmountOfIter) >=
            fullAuctionedAmount.mul(sellAmountOfIter)
        ) {
            // All considered/summed orders are sufficient to close the auction fully
            // at price between current and previous orders.
            uint256 uncoveredBids = currentBidSum.sub(
                fullAuctionedAmount.mul(sellAmountOfIter).div(buyAmountOfIter)
            );

            if (sellAmountOfIter >= uncoveredBids) {
                //[13]
                // Auction fully filled via partial match of currentOrder
                uint256 sellAmountClearingOrder = sellAmountOfIter.sub(
                    uncoveredBids
                );
                auctionData[auctionId]
                .volumeClearingPriceOrder = sellAmountClearingOrder.toUint96();
                currentBidSum = currentBidSum.sub(uncoveredBids);
                clearingOrder = currentOrder;
            } else {
                //[14]
                // Auction fully filled via price strictly between currentOrder and the order
                // immediately before. For a proof, see the security-considerations.md
                currentBidSum = currentBidSum.sub(sellAmountOfIter);
                clearingOrder = IterableOrderedOrderSet.encodeOrder(
                    0,
                    fullAuctionedAmount,
                    currentBidSum.toUint96()
                );
            }
        } else {
            // All considered/summed orders are not sufficient to close the auction fully at price of last order //[18]
            // Either a higher price must be used or auction is only partially filled

            if (currentBidSum > minAuctionedBuyAmount) {
                //[15]
                // Price higher than last order would fill the auction
                clearingOrder = IterableOrderedOrderSet.encodeOrder(
                    0,
                    fullAuctionedAmount,
                    currentBidSum.toUint96()
                );
            } else {
                //[16]
                // Even at the initial auction price, the auction is partially filled
                clearingOrder = IterableOrderedOrderSet.encodeOrder(
                    0,
                    fullAuctionedAmount,
                    minAuctionedBuyAmount
                );
                fillVolumeOfAuctioneerOrder = currentBidSum
                .mul(fullAuctionedAmount)
                .div(minAuctionedBuyAmount)
                .toUint96();
            }
        }
        clearingPriceOrders[auctionId] = clearingOrder;
        if (auctionData[auctionId].minFundingThreshold > currentBidSum) {
            auctionData[auctionId].minFundingThresholdNotReached = true;
        }

        processFeesAndAuctioneerFunds(
            auctionId,
            fillVolumeOfAuctioneerOrder,
            auctioneerId,
            fullAuctionedAmount
        );
        emit AuctionCleared(
            auctionId,
            fillVolumeOfAuctioneerOrder,
            uint96(currentBidSum),
            clearingOrder
        );
        // Gas refunds
        auctionAccessManager[auctionId] = address(0);
        delete auctionAccessData[auctionId];
        auctionData[auctionId].initialAuctionOrder = bytes32(0);
        auctionData[auctionId].interimOrder = bytes32(0);
        auctionData[auctionId].interimSumBidAmount = uint256(0);
        auctionData[auctionId].minimumBiddingAmountPerOrder = uint256(0);
    }

    /**

    First we will remove the given orders from contract sell orders list.
    **/
    function claimFromParticipantOrder(
        uint256 auctionId,
        bytes32[] memory orders
    )
        public
        atStageFinished(auctionId)
        returns (
            uint256 sumBiddingTokenAmount,
            uint256 rSumBiddingTokenAmount,
            uint256 lpTokens
        )
    {
        for (uint256 i = 0; i < orders.length; i++) {
            // Note: we don't need to keep any information about the node since
            // no new elements need to be inserted.
            require(sellOrders[auctionId].remove(orders[i]), "NOT_CLAIMABLE");
        }
        AuctionData memory auction = auctionData[auctionId];
        bytes32 clearingPriceOrder = clearingPriceOrders[auctionId];
        // (, uint96 priceNumerator, uint96 priceDenominator) = clearingPriceOrder
        // .decodeOrder();

        (uint64 userId, , ) = orders[0].decodeOrder();
        bool minFundingThresholdNotReached = auction
        .minFundingThresholdNotReached;
        for (uint256 i = 0; i < orders.length; i++) {
            (uint64 userIdOrder, uint96 buyAmount, uint96 sellAmount) = orders[
                i
            ]
            .decodeOrder();
            require(userIdOrder == userId, "SAME_USER_CAN_CLAIM");
            if (minFundingThresholdNotReached) {
                //[10]
                rSumBiddingTokenAmount = rSumBiddingTokenAmount.add(sellAmount);
            } else {
                //[23]
                if (orders[i] == clearingPriceOrder) {
                    //[25]
                    {
                        sumBiddingTokenAmount = sumBiddingTokenAmount.add(
                            sellAmount
                        );

                        rSumBiddingTokenAmount = rSumBiddingTokenAmount.add(
                            sellAmount.sub(auction.volumeClearingPriceOrder)
                        );
                    }
                    emit Bidder(
                        auctionId,
                        buyAmount,
                        sellAmount,
                        userIdOrder,
                        "SUCCESS"
                    );
                } else {
                    if (orders[i].smallerThan(clearingPriceOrder)) {
                        //[17]
                        // In case of successful order:
                        // Don't need to calculate sumAuctioningTokenAmount because we are not sending auctioning tokens to
                        // the bidder so here we will calculate sumBiddingTokenAmount and conside this order as a successful order
                        {
                            sumBiddingTokenAmount = sumBiddingTokenAmount.add(
                                sellAmount
                            );
                        }
                        emit Bidder(
                            auctionId,
                            buyAmount,
                            sellAmount,
                            userIdOrder,
                            "SUCCESS"
                        );
                    } else {
                        //[24]
                        // In case of unsuccessful order we will calculate totalBiddingToken
                        //amount to return it to the bidder.
                        {
                            rSumBiddingTokenAmount = rSumBiddingTokenAmount.add(
                                sellAmount
                            );
                        }
                        emit Bidder(
                            auctionId,
                            buyAmount,
                            sellAmount,
                            userIdOrder,
                            "FAIL"
                        );
                    }
                }
            }
            emit ClaimedFromOrder(auctionId, userId, buyAmount, sellAmount);
        }

        // here we will calculate user lp tokens using his bidding tokens
        // if minimum funding threshold is not reached then we will simply
        //send back his bidding tokens otherwise we will send his lp tokens.
        if (minFundingThresholdNotReached) {
            sendOutTokens(auctionId, 0, rSumBiddingTokenAmount, userId); //[3]
        }
        if (!minFundingThresholdNotReached) {
            sendOutTokens(auctionId, 0, rSumBiddingTokenAmount, userId); //[3]

            if (sumBiddingTokenAmount > 0) {
                lpTokens = calculateLPTokens(auctionId, sumBiddingTokenAmount);
                IPancakeswapV2Pair(liquidityPools[auctionId]).transfer(
                    registeredUsers.getAddressAt(userId),
                    lpTokens
                );
                emit ClaimedLPFromOrder(
                    auctionId,
                    userId,
                    sumBiddingTokenAmount,
                    lpTokens
                );
            }
        }
    }

    function processFeesAndAuctioneerFunds(
        uint256 auctionId,
        uint256 fillVolumeOfAuctioneerOrder,
        uint64 auctioneerId,
        uint96 fullAuctionedAmount
    ) internal {
        uint256 feeAmount = fullAuctionedAmount
        .mul(auctionData[auctionId].feeNumerator)
        .div(FEE_DENOMINATOR); //[20]
        // if minimum funding threshold is not reached we will send back all auctioning tokens
        // to the auctioneer
        if (auctionData[auctionId].minFundingThresholdNotReached) {
            sendOutTokens(
                auctionId,
                fullAuctionedAmount.add(feeAmount),
                0,
                auctioneerId
            ); //[4]
        } else {
            //[11]
            (
                ,
                uint96 priceNumerator,
                uint96 priceDenominator
            ) = clearingPriceOrders[auctionId].decodeOrder();
            // fillVolumeOfAuctioneerOrder is the amount of tokens that is filled
            // fullAuctionedAmount is the amount of tokens that is auctioned by auctioneer
            // unsettledAuctionTokens = fullAuctionedAmount - fillVolumeOfAuctioneerOrder
            // remaining auctioning tokens which are not sold
            uint256 unsettledAuctionTokens = fullAuctionedAmount.sub(
                fillVolumeOfAuctioneerOrder
            );
            // auctioningTokenAmount = unsettledAuctionTokens + ( ( feeAmount * unsettledAuctionTokens ) / fullAuctionedAmount)
            // unsettled auctioning tokens which will be sent back to the auctioneer
            uint256 auctioningTokenAmount = unsettledAuctionTokens.add(
                feeAmount.mul(unsettledAuctionTokens).div(fullAuctionedAmount)
            );
            // biddingTokenAmount = (fillVolumeOfAuctioneerOrder * priceDenominator) / priceNumerator
            // biddingTokenAmount is the amount of tokens which has been collected against sold auctioning tokens
            uint256 biddingTokenAmount = fillVolumeOfAuctioneerOrder
            .mul(priceDenominator)
            .div(priceNumerator);

            // instead of send bidding tokens to the auctioneer account we will add these bidding tokens
            // to the pool with total auctioned amount of tokens.
            uint256 liquidity = addLiquidity(
                auctionId,
                fillVolumeOfAuctioneerOrder, // just add the sold amount of auctioning tokens to the pool
                biddingTokenAmount
            );
            poolLiquidities[auctionId] = liquidity;
            emit AddLiquidity(auctionId, liquidity);
            sendOutTokens(auctionId, auctioningTokenAmount, 0, auctioneerId); //[5]
            // (feeAmount * fillVolumeOfAuctioneerOrder) / fullAuctionedAmount
            sendOutTokens(
                auctionId,
                feeAmount.mul(fillVolumeOfAuctioneerOrder).div(
                    fullAuctionedAmount
                ),
                0,
                feeReceiverUserId
            ); //[7]
        }
    }

    function calculateLPTokens(uint256 auctionId, uint256 biddingTokenAmount)
        public
        view
        returns (uint256)
    {
        require(startingDate[auctionId] != 0, "NOT_EXIST");
        uint256 totalBiddingTokenAmount = auctionData[auctionId].interimSumBidAmount;

        if (totalBiddingTokenAmount == 0) {
            return 0;
        }
        uint256 totalLP = poolLiquidities[auctionId];
        return
            biddingTokenAmount
                .mul(10**18)
                .div(totalBiddingTokenAmount)
                .mul(totalLP.div(2))
                .div(10**18);
    }

    function addLiquidity(
        uint256 auctionId,
        uint256 auctionTokenAmount,
        uint256 biddingTokenAmount
    ) internal returns (uint256 liquidity) {
        // approve token transfer to cover all possible scenarios
        AuctionData storage auction = auctionData[auctionId];
        auction.auctioningToken.approve(
            address(pancakeswapV2Router[auctionId]),
            auctionTokenAmount
        );
        auction.biddingToken.approve(
            address(pancakeswapV2Router[auctionId]),
            biddingTokenAmount
        );
        // add the liquidity
        (, , liquidity) = IPancakeswapV2Router02(pancakeswapV2Router[auctionId])
        .addLiquidity(
            address(auction.auctioningToken),
            address(auction.biddingToken),
            auctionTokenAmount,
            biddingTokenAmount,
            0,
            0,
            address(this),
            block.timestamp + 600
        );
        liquidityPools[auctionId] = IPancakeswapV2Factory(
            IPancakeswapV2Router02(pancakeswapV2Router[auctionId]).factory()
        ).getPair(
            address(auction.auctioningToken),
            address(auction.biddingToken)
        );
    }

    /* send back either auctioning or bidding tokens to the given user.
    Transfers out occur on:
    1- order cancellation,giving back the amount bid by the user in an order.
    2- users claiming funds after the auction is concluded 
    3- auction closing and sending
        1-funds to the auctioneer
        2-fees to the dedicated address
    */
    function sendOutTokens(
        uint256 auctionId,
        uint256 auctioningTokenAmount,
        uint256 biddingTokenAmount,
        uint64 userId
    ) internal {
        address userAddress = registeredUsers.getAddressAt(userId);
        if (auctioningTokenAmount > 0) {
            auctionData[auctionId].auctioningToken.safeTransfer(
                userAddress,
                auctioningTokenAmount
            );
        }
        if (biddingTokenAmount > 0) {
            auctionData[auctionId].biddingToken.safeTransfer(
                userAddress,
                biddingTokenAmount
            );
        }
    }

    function registerUser(address user) public returns (uint64) {
        numUsers = numUsers.add(1).toUint64();
        require(
            registeredUsers.insert(numUsers, user),
            "REGISTERED" // User already registered
        );
        emit UserRegistration(user, numUsers);
        return numUsers;
    }

    function getUserAddress(uint256 userId) external view returns (address) {
        return
            registeredUsers.hasId(userId.toUint64()) == true
                ? registeredUsers.getAddressAt(userId.toUint64())
                : address(0);
    }

    function getUserId(address user) public returns (uint64 userId) {
        if (registeredUsers.hasAddress(user)) {
            userId = registeredUsers.getId(user);
        } else {
            userId = registerUser(user);
            emit NewUser(userId, user);
        }
    }

    function getSecondsRemainingInBatch(uint256 auctionId)
        public
        view
        returns (uint256)
    {
        if (auctionData[auctionId].auctionEndDate < block.timestamp) {
            return 0;
        }
        return auctionData[auctionId].auctionEndDate.sub(block.timestamp);
    }

    function containsOrder(uint256 auctionId, bytes32 order)
        public
        view
        returns (bool)
    {
        return sellOrders[auctionId].contains(order);
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

    function setRouters(address[] memory _routers) external onlyOwner {
        for (uint8 i = 0; i < _routers.length; i++) {
            routers.push(_routers[i]);
        }
        emit AddRouters(_routers);
    }

    function setDocumentAddress(address _document) external onlyOwner {
        documents = IDocuments(_document);
    }

    function getAuctionInfo(uint256 auctionId)
        external
        view
        atStageFinished(auctionId)
        returns (
            uint256 auctioningToken,
            uint256 biddingToken,
            uint112 reserve0,
            uint112 reserve1
        )
    {
        auctioningToken = auctionData[auctionId].auctioningToken.balanceOf(
            address(this)
        );
        biddingToken = auctionData[auctionId].biddingToken.balanceOf(
            address(this)
        );
        (reserve0, reserve1, ) = IPancakeswapV2Pair(liquidityPools[auctionId])
        .getReserves();
    }

    // Every successful bid will be the part of lp token price
    // If a bidder will cancel his order it will not effect the
    // lp token price.
    // function getLpPrice(uint256 auctionId)
    //     external
    //     view
    //     atStageFinished(auctionId)
    //     returns (uint96 averagePrice, uint256 counter)
    // {
    //     (averagePrice, counter) = sellOrders[auctionId].average();
    // }

    // function userAuctionStatus(uint256 auctionId, address user)
    //     external
    //     view
    //     returns (bool isAuctionSuccess, uint96 purchased)
    // {
    //     isAuctionSuccess = auctionData[auctionId].minFundingThresholdNotReached;

    // }

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

    function getDocumentName(uint256 _index)
        external
        view
        returns (string memory)
    {
        return documents.getDocumentName(_index);
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
