// SPDX-License-Identifier: MIT
pragma solidity >=0.6.8;

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

    /**
    @param {auctioningToken}
    **/
    struct AuctionData {
        IERC20 auctioningToken;
        IERC20 biddingToken;
        IPancakeswapV2Pair pancakeswapV2Pair;
        uint256 orderCancellationEndDate;
        uint256 auctionEndDate;
        bytes32 initialAuctionOrder;
        uint256 minimumBiddingAmountPerOrder;
        uint256 interimSumBidAmount;
        bytes32 interimOrder;
        bytes32 clearingPriceOrder;
        uint96 volumeClearingPriceOrder;
        bool minFundingThresholdNotReached;
        bool isAtomicClosureAllowed;
        uint256 feeNumerator;
        uint256 minFundingThreshold;
    }
    mapping(uint256 => IterableOrderedOrderSet.Data) internal sellOrders; // Store total number of sell orders
    mapping(uint256 => AuctionData) public auctionData; // Store auctions details
    mapping(uint256 => address) public auctionAccessManager;
    mapping(uint256 => bytes) public auctionAccessData;

    IDocuments public immutable documents; // for storing documents
    // IERC20 public annexToken;
    IPancakeswapV2Router02 public immutable pancakeswapV2Router;

    IdToAddressBiMap.Data private registeredUsers;
    uint256 public auctionCounter; // counter for auctions
    uint256 public feeNumerator = 0;
    uint256 public constant FEE_DENOMINATOR = 1000;
    uint256 public threshold = 100 ether; // 100 ANN

    uint64 public feeReceiverUserId = 1;
    uint64 public numUsers; // counter of users
    bool public inSwapAndLiquify;

    modifier atStageOrderPlacement(uint256 auctionId) {
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
                    auctionData[auctionId].clearingPriceOrder == bytes32(0),
                "ERROR_SOL_SUB"
            );
        }
        _;
    }

    modifier atStageFinished(uint256 auctionId) {
        require(
            auctionData[auctionId].clearingPriceOrder != bytes32(0),
            "ERROR_NOT_FINSIHED"
        );
        _;
    }

    modifier lockTheSwap {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
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
        uint64 indexed userId,
        uint256 lp
    );

    event NewUser(uint64 indexed userId, address indexed userAddress);
    event NewAuction(
        uint256 indexed auctionId,
        IERC20 indexed _auctioningToken,
        IERC20 indexed _biddingToken,
        uint256 orderCancellationEndDate,
        uint256 auctionEndDate,
        uint64 userId,
        uint96 _auctionedSellAmount,
        uint96 _minBuyAmount,
        uint256 minimumBiddingAmountPerOrder,
        uint256 minFundingThreshold,
        address allowListContract,
        bytes allowListData,
        address lp
    );
    event AuctionCleared(
        uint256 indexed auctionId,
        uint96 soldAuctioningTokens,
        uint96 soldBiddingTokens,
        bytes32 clearingPriceOrder,
        uint256 liquidity
    );
    event UserRegistration(address indexed user, uint64 userId);

    constructor(
        address _router,
        address _documents
    ) public Ownable() {
        documents = IDocuments(_documents);
        pancakeswapV2Router = IPancakeswapV2Router02(_router);
    }

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

    function initiateAuction(
        IERC20 _auctioningToken,
        IERC20 _biddingToken,
        uint256 orderCancellationEndDate,
        uint256 auctionEndDate,
        uint96 _auctionedSellAmount,
        uint96 _minBuyAmount,
        uint256 minimumBiddingAmountPerOrder,
        uint256 minFundingThreshold,
        bool isAtomicClosureAllowed,
        address accessManagerContract,
        bytes memory accessManagerContractData
    ) public returns (uint256) {
        /* 
        ( _auctionedSellAmount * ( 1000 + feeNumerator ) ) / 1000
        // withdraws sellAmount + fees
        // i.e: autionTokens = 1000
        // fees = 1%
        then 1010 will be added to the contract
        */
        // Auctioner can init an auction if he has 100 Ann
        require(_biddingToken.balanceOf(msg.sender) >= 100, "NOT_ENOUGH_ANN");
        _auctioningToken.safeTransferFrom(
            msg.sender,
            address(this),
            _auctionedSellAmount.mul(FEE_DENOMINATOR.add(feeNumerator)).div(
                FEE_DENOMINATOR
            ) //[0]
        );
        require(_auctionedSellAmount > 0, "INVALID_AUCTION_TOKENS"); //
        require(_minBuyAmount > 0, "TOKENS_CANT_AUCTIONED_FREE"); // tokens cannot be auctioned for free
        require(minimumBiddingAmountPerOrder > 0, "MUST_NOT_ZERO");
        require(
            orderCancellationEndDate <= auctionEndDate,
            "ERROR_TIME_PERIOD"
        );
        require(auctionEndDate > block.timestamp, "INVALID_AUTION_END");
        auctionCounter = auctionCounter.add(1);
        sellOrders[auctionCounter].initializeEmptyList();
        uint64 userId = getUserId(msg.sender);
        address pancakeswapV2Pair = IPancakeswapV2Factory(
            pancakeswapV2Router.factory()
        ).createPair(address(_auctioningToken), address(_biddingToken));

        auctionData[auctionCounter] = AuctionData(
            _auctioningToken,
            _biddingToken,
            IPancakeswapV2Pair(pancakeswapV2Pair),
            orderCancellationEndDate,
            auctionEndDate,
            IterableOrderedOrderSet.encodeOrder(
                userId,
                _minBuyAmount,
                _auctionedSellAmount
            ),
            minimumBiddingAmountPerOrder,
            0,
            IterableOrderedOrderSet.QUEUE_START,
            bytes32(0),
            0,
            false,
            isAtomicClosureAllowed,
            feeNumerator,
            minFundingThreshold
        );
        auctionAccessManager[auctionCounter] = accessManagerContract;
        auctionAccessData[auctionCounter] = accessManagerContractData;

        emit NewAuction(
            auctionCounter,
            _auctioningToken,
            _biddingToken,
            orderCancellationEndDate,
            auctionEndDate,
            userId,
            _auctionedSellAmount,
            _minBuyAmount,
            minimumBiddingAmountPerOrder,
            minFundingThreshold,
            accessManagerContract,
            accessManagerContractData,
            pancakeswapV2Pair
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

    // @dev function settling the auction and calculating the price
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
        auctionData[auctionId].clearingPriceOrder = clearingOrder;

        if (auctionData[auctionId].minFundingThreshold > currentBidSum) {
            auctionData[auctionId].minFundingThresholdNotReached = true;
        }

        (, , uint256 liquidity) = addLiquidity(
            auctionId,
            fullAuctionedAmount,
            fillVolumeOfAuctioneerOrder
        );
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
            clearingOrder,
            liquidity
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
            uint256 sumAuctioningTokenAmount,
            uint256 sumBiddingTokenAmount
        )
    {
        for (uint256 i = 0; i < orders.length; i++) {
            // Note: we don't need to keep any information about the node since
            // no new elements need to be inserted.
            require(sellOrders[auctionId].remove(orders[i]), "NOT_CLAIMABLE");
        }
        AuctionData memory auction = auctionData[auctionId];
        (, uint96 priceNumerator, uint96 priceDenominator) = auction
        .clearingPriceOrder
        .decodeOrder();

        (uint64 userId, , ) = orders[0].decodeOrder();
        bool minFundingThresholdNotReached = auctionData[auctionId]
        .minFundingThresholdNotReached;
        for (uint256 i = 0; i < orders.length; i++) {
            (uint64 userIdOrder, uint96 buyAmount, uint96 sellAmount) = orders[i]
            .decodeOrder();
            require(userIdOrder == userId, "SAME_USER_CAN_CLAIM");
            if (minFundingThresholdNotReached) {
                //[10]
                sumBiddingTokenAmount = sumBiddingTokenAmount.add(sellAmount);
            } else {
                //[23]
                if (orders[i] == auction.clearingPriceOrder) {
                    //[25]
                    sumAuctioningTokenAmount = sumAuctioningTokenAmount.add(
                        auction
                        .volumeClearingPriceOrder
                        .mul(priceNumerator)
                        .div(priceDenominator)
                    );
                    sumBiddingTokenAmount = sumBiddingTokenAmount.add(
                        sellAmount.sub(auction.volumeClearingPriceOrder)
                    );
                } else {
                    if (orders[i].smallerThan(auction.clearingPriceOrder)) {
                        //[17]
                        sumAuctioningTokenAmount = sumAuctioningTokenAmount.add(
                            sellAmount.mul(priceNumerator).div(priceDenominator)
                        );
                    } else {
                        //[24]
                        sumBiddingTokenAmount = sumBiddingTokenAmount.add(
                            sellAmount
                        );
                    }
                }
            }
            emit ClaimedFromOrder(auctionId, userId, buyAmount, sellAmount);
        }

        uint256 lp = calculateLPTokens(auctionId, sumBiddingTokenAmount);
        auction.pancakeswapV2Pair.transfer(
            registeredUsers.getAddressAt(userId),
            lp
        );
        emit ClaimedLPFromOrder(auctionId, userId, lp);
        // sendOutTokens(
        //     auctionId,
        //     sumAuctioningTokenAmount,
        //     sumBiddingTokenAmount,
        //     userId
        // ); //[3]
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
        if (auctionData[auctionId].minFundingThresholdNotReached) {
            sendOutTokens(
                auctionId,
                fullAuctionedAmount.add(feeAmount),
                0,
                auctioneerId
            ); //[4]
        } else {
            //[11]
            (, uint96 priceNumerator, uint96 priceDenominator) = auctionData[
                auctionId
            ]
            .clearingPriceOrder
            .decodeOrder();
            // unsettledAuctionTokens = fullAuctionedAmount - fillVolumeOfAuctioneerOrder
            // remaining auctioning tokens which are not sold
            uint256 unsettledAuctionTokens = fullAuctionedAmount.sub(
                fillVolumeOfAuctioneerOrder
            );
            // auctioningTokenAmount = unsettledAuctionTokens + ( ( feeAmount * unsettledAuctionTokens ) / fullAuctionedAmount)
            // remaining auctioning tokens which are sold
            uint256 auctioningTokenAmount = unsettledAuctionTokens.add(
                feeAmount.mul(unsettledAuctionTokens).div(fullAuctionedAmount)
            );
            // biddingTokenAmount = (fillVolumeOfAuctioneerOrder * priceDenominator) / priceNumerator
            uint256 biddingTokenAmount = fillVolumeOfAuctioneerOrder
            .mul(priceDenominator)
            .div(priceNumerator);
            sendOutTokens(
                auctionId,
                auctioningTokenAmount,
                biddingTokenAmount,
                auctioneerId
            ); //[5]
            sendOutTokens(
                auctionId,
                // (feeAmount * fillVolumeOfAuctioneerOrder) / fullAuctionedAmount
                feeAmount.mul(fillVolumeOfAuctioneerOrder).div(
                    fullAuctionedAmount
                ),
                0,
                feeReceiverUserId
            ); //[7]
        }
    }

    function calculateLPTokens(uint256 auctionId, uint256 biddingTokenAmount)
        internal
        view
        returns (uint256)
    {
        AuctionData storage auction = auctionData[auctionId];
        (, , uint96 totalBiddingTokenAmount) = auction
        .clearingPriceOrder
        .decodeOrder(); // fetching total bidding amounts of tokens from clearing price order
        uint256 totalLP = IPancakeswapV2Pair(auction.pancakeswapV2Pair)
        .balanceOf(address(this));
        return (
            biddingTokenAmount.div(totalBiddingTokenAmount).mul(totalLP.div(2))
        );
    }

    function addLiquidity(
        uint256 auctionId,
        uint256 auctionTokenAmount,
        uint256 biddingTokenAmount
    )
        internal
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        )
    {
        // approve token transfer to cover all possible scenarios

        AuctionData storage auction = auctionData[auctionId];
        auction.auctioningToken.approve(
            address(pancakeswapV2Router),
            auctionTokenAmount
        );
        auction.biddingToken.approve(
            address(pancakeswapV2Router),
            biddingTokenAmount
        );
        // add the liquidity
        return
            pancakeswapV2Router.addLiquidity(
                address(auction.auctioningToken),
                address(auction.biddingToken),
                auctionTokenAmount,
                biddingTokenAmount,
                0,
                0,
                address(this),
                block.timestamp + 600
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

    function registerUser(address user) public returns (uint64 userId) {
        numUsers = numUsers.add(1).toUint64();
        require(
            registeredUsers.insert(numUsers, user),
            "REGISTERED" // User already registered
        );
        // userId = numUsers;
        emit UserRegistration(user, numUsers);
    }

    function getUserId(address user) public returns (uint64 userId) {
        if (registeredUsers.hasAddress(user)) {
            userId = registeredUsers.getId(user);
        } else {
            // userId = registerUser(user);
            emit NewUser(registerUser(user), user);
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
    // Documents
    //--------------------------------------------------------

    function setDocument(string calldata _name, string calldata _data)
        external
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
