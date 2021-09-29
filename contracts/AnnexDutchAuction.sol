// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./Access/Governable.sol";
import "./interfaces/IAnnexStake.sol";

contract AnnexDutchAuction is Configurable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address;
    bytes32 internal constant TxFeeRatio = bytes32("TxFeeRatio");
    bytes32 internal constant MinValueOfBotHolder =
        bytes32("MinValueOfBotHolder");
    bytes32 internal constant BotToken = bytes32("BotToken");
    bytes32 internal constant StakeContract = bytes32("StakeContract");
    struct CreateReq {
        string name;
        address payable creator;
        address token0;
        address token1;
        uint256 amountTotal0;
        uint256 amountMax1;
        uint256 amountMin1;
        uint256 times;
        uint256 openAt;
        uint256 closeAt;
        bool onlyBot;
        bool enableWhiteList;
    }
    struct Pool {
        string name;
        address payable creator;
        address token0;
        address token1;
        uint256 amountTotal0;
        uint256 amountMax1;
        uint256 amountMin1;
        uint256 times;
        uint256 duration;
        uint256 openAt;
        uint256 closeAt;
        bool enableWhiteList;
    }
    Pool[] public pools;
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
    event Created(uint256 indexed index, address indexed sender, Pool pool);
    event Bid(
        uint256 indexed index,
        address indexed sender,
        uint256 amount0,
        uint256 amount1
    );
    event Claimed(
        uint256 indexed index,
        address indexed sender,
        uint256 unFilledAmount0
    );
    function initialize() public initializer {
 
        config[TxFeeRatio] = 0.005 ether; // 0.5%
        config[MinValueOfBotHolder] = 60 ether;
        config[BotToken] = uint256(uint160(0xA9B1Eb5908CfC3cdf91F9B8B3a74108598009096)); // AUCTION
        config[StakeContract] = uint256(
            uint160(0x98945BC69A554F8b129b09aC8AfDc2cc2431c48E)
        );
    }
    function initialize_rinkeby() public {
        initialize();
        config[BotToken] = uint256(uint160(0x5E26FA0FE067d28aae8aFf2fB85Ac2E693BD9EfA)); // AUCTION
        config[StakeContract] = uint256(
            uint160(0xa77A9FcbA2Ae5599e0054369d1655D186020ECE1)
        );
    }
    function initialize_bsc() public {
        initialize();
        config[BotToken] = uint256(uint160(0x1188d953aFC697C031851169EEf640F23ac8529C)); // AUCTION
        config[StakeContract] = uint256(
            uint160(0x1dd665ba1591756aa87157F082F175bDcA9fB91a)
        );
    }
    function create(CreateReq memory poolReq, address[] memory whitelist_)
        external
        nonReentrant
    {
        require(tx.origin == msg.sender, "disallow contract caller");
        require(poolReq.amountTotal0 != 0, "the value of amountTotal0 is zero");
        require(poolReq.amountMin1 != 0, "the value of amountMax1 is zero");
        require(poolReq.amountMax1 != 0, "the value of amountMin1 is zero");
        require(
            poolReq.amountMax1 > poolReq.amountMin1,
            "amountMax1 should larger than amountMin1"
        );
        require(
            poolReq.openAt <= poolReq.closeAt &&
                poolReq.closeAt.sub(poolReq.openAt) < 7 days,
            "invalid closed"
        );
        require(poolReq.times != 0, "the value of times is zero");
        require(
            bytes(poolReq.name).length <= 15,
            "the length of name is too long"
        );
        uint256 index = pools.length;
        IERC20 _token0 = IERC20(poolReq.token0);
        uint256 token0BalanceBefore = _token0.balanceOf(address(this));
        _token0.safeTransferFrom(
            poolReq.creator,
            address(this),
            poolReq.amountTotal0
        );
        require(
            _token0.balanceOf(address(this)).sub(token0BalanceBefore) ==
                poolReq.amountTotal0,
            "not support deflationary token"
        );
        if (poolReq.enableWhiteList) {
            require(whitelist_.length > 0, "no whitelist imported");
            _addWhitelist(index, whitelist_);
        }
        Pool memory pool;
        pool.name = poolReq.name;
        pool.creator = poolReq.creator;
        pool.token0 = poolReq.token0;
        pool.token1 = poolReq.token1;
        pool.amountTotal0 = poolReq.amountTotal0;
        pool.amountMax1 = poolReq.amountMax1;
        pool.amountMin1 = poolReq.amountMin1;
        pool.times = poolReq.times;
        pool.duration = poolReq.closeAt.sub(poolReq.openAt);
        pool.openAt = poolReq.openAt;
        pool.closeAt = poolReq.closeAt;
        pool.enableWhiteList = poolReq.enableWhiteList;
        pools.push(pool);
        if (poolReq.onlyBot) {
            onlyBotHolderP[index] = poolReq.onlyBot;
        }
        myCreatedP[poolReq.creator] = pools.length;
        emit Created(index, msg.sender, pool);
    }
    function bid(
        uint256 index,
        uint256 amount0,
        uint256 amount1
    )
        external
        payable
        nonReentrant
        isPoolExist(index)
        checkBotHolder(index)
        isPoolNotClosed(index)
    {
        address payable sender = payable(msg.sender) ;
        require(tx.origin == msg.sender, "disallow contract caller");
        if (enableWhiteList) {
            require(whitelistP[index][sender], "sender not in whitelist");
        }
        Pool memory pool = pools[index];
        require(pool.openAt <= block.timestamp , "pool not open");
        require(amount0 != 0, "the value of amount0 is zero");
        require(amount1 != 0, "the value of amount1 is zero");
        require(pool.amountTotal0 > amountSwap0P[index], "swap amount is zero");
        uint256 curPrice = currentPrice(index);
        uint256 bidPrice = amount1.mul(1 ether).div(amount0);
        require(
            bidPrice >= curPrice,
            "the bid price is lower than the current price"
        );
        if (lowestBidPrice[index] == 0 || lowestBidPrice[index] > bidPrice) {
            lowestBidPrice[index] = bidPrice;
        }
        address token1 = pool.token1;
        if (token1 == address(0)) {
            require(amount1 == msg.value, "invalid ETH amount");
        } else {
            IERC20(token1).safeTransferFrom(sender, address(this), amount1);
        }
        _swap(sender, index, amount0, amount1);
        emit Bid(index, sender, amount0, amount1);
    }
    function creatorClaim(uint256 index)
        external
        nonReentrant
        isPoolExist(index)
        isPoolClosed(index)
    {
        address payable creator = payable(msg.sender);
        require(isCreator(creator, index), "sender is not pool creator");
        require(!creatorClaimedP[index], "creator has claimed this pool");
        creatorClaimedP[index] = true;
        delete myCreatedP[creator];
        Pool memory pool = pools[index];
        uint256 unFilledAmount0 = pool.amountTotal0.sub(amountSwap0P[index]);
        if (unFilledAmount0 > 0) {
            IERC20(pool.token0).safeTransfer(creator, unFilledAmount0);
        }
        uint256 amount1 = lowestBidPrice[index].mul(amountSwap0P[index]).div(
            1 ether
        );
        if (amount1 > 0) {
            if (pool.token1 == address(0)) {
                uint256 txFee = amount1.mul(getTxFeeRatio()).div(1 ether);
                uint256 _actualAmount1 = amount1.sub(txFee);
                if (_actualAmount1 > 0) {
                    pool.creator.transfer(_actualAmount1);
                }
                if (txFee > 0) {
                    IAnnexStake(getStakeContract()).depositReward{
                        value: txFee
                    }();
                }
            } else {
                IERC20(pool.token1).safeTransfer(pool.creator, amount1);
            }
        }
        emit Claimed(index, creator, unFilledAmount0);
    }
    function bidderClaim(uint256 index)
        external
        nonReentrant
        isPoolExist(index)
        isPoolClosed(index)
    {
        address payable bidder = payable(msg.sender);
        require(!bidderClaimedP[bidder][index], "bidder has claimed this pool");
        bidderClaimedP[bidder][index] = true;
        Pool memory pool = pools[index];
        if (myAmountSwap0P[bidder][index] > 0) {
            IERC20(pool.token0).safeTransfer(
                bidder,
                myAmountSwap0P[bidder][index]
            );
        }
        uint256 actualAmount1 = lowestBidPrice[index]
            .mul(myAmountSwap0P[bidder][index])
            .div(1 ether);
        uint256 unfilledAmount1 = myAmountSwap1P[bidder][index].sub(
            actualAmount1
        );
        if (unfilledAmount1 > 0) {
            if (pool.token1 == address(0)) {
                bidder.transfer(unfilledAmount1);
            } else {
                IERC20(pool.token1).safeTransfer(bidder, unfilledAmount1);
            }
        }
    }
    function _swap(
        address payable sender,
        uint256 index,
        uint256 amount0,
        uint256 amount1
    ) private {
        Pool memory pool = pools[index];
        uint256 _amount0 = pool.amountTotal0.sub(amountSwap0P[index]);
        uint256 _amount1 = 0;
        uint256 _excessAmount1 = 0;
        if (_amount0 < amount0) {
            _amount1 = _amount0.mul(amount1).div(amount0);
            _excessAmount1 = amount1.sub(_amount1);
        } else {
            _amount0 = amount0;
            _amount1 = amount1;
        }
        myAmountSwap0P[sender][index] = myAmountSwap0P[sender][index].add(
            _amount0
        );
        myAmountSwap1P[sender][index] = myAmountSwap1P[sender][index].add(
            _amount1
        );
        amountSwap0P[index] = amountSwap0P[index].add(_amount0);
        amountSwap1P[index] = amountSwap1P[index].add(_amount1);
        if (_excessAmount1 > 0) {
            if (pool.token1 == address(0)) {
                sender.transfer(_excessAmount1);
            } else {
                IERC20(pool.token1).safeTransfer(sender, _excessAmount1);
            }
        }
    }
    function isCreator(address target, uint256 index)
        private
        view
        returns (bool)
    {
        if (pools[index].creator == target) {
            return true;
        }
        return false;
    }
    function currentPrice(uint256 index) public view returns (uint256) {
        Pool memory pool = pools[index];
        uint256 _amount1 = pool.amountMin1;
        uint256 realTimes = pool.times.add(1);
        if (block.timestamp < pool.closeAt) {
            uint256 stepInSeconds = pool.duration.div(realTimes);
            if (stepInSeconds != 0) {
                uint256 remainingTimes = pool.closeAt.sub(block.timestamp).sub(1).div(
                    stepInSeconds
                );
                if (remainingTimes != 0) {
                    _amount1 = pool
                        .amountMax1
                        .sub(pool.amountMin1)
                        .mul(remainingTimes)
                        .div(pool.times)
                        .add(pool.amountMin1);
                }
            }
        }
        return _amount1.mul(1 ether).div(pool.amountTotal0);
    }
    function nextRoundInSeconds(uint256 index) public view returns (uint256) {
        Pool memory pool = pools[index];
        if (block.timestamp >= pool.closeAt) return 0;
        uint256 realTimes = pool.times.add(1);
        uint256 stepInSeconds = pool.duration.div(realTimes);
        if (stepInSeconds == 0) return 0;
        uint256 remainingTimes = pool.closeAt.sub(block.timestamp).sub(1).div(
            stepInSeconds
        );
        return pool.closeAt.sub(remainingTimes.mul(stepInSeconds)).sub(block.timestamp);
    }
    function _addWhitelist(uint256 index, address[] memory whitelist_) private {
        for (uint256 i = 0; i < whitelist_.length; i++) {
            whitelistP[index][whitelist_[i]] = true;
        }
    }
    function addWhitelist(uint256 index, address[] memory whitelist_) external {
        require(
            owner() == msg.sender || pools[index].creator == msg.sender,
            "no permission"
        );
        _addWhitelist(index, whitelist_);
    }
    function removeWhitelist(uint256 index, address[] memory whitelist_)
        external
    {
        require(
            owner() == msg.sender || pools[index].creator == msg.sender,
            "no permission"
        );
        for (uint256 i = 0; i < whitelist_.length; i++) {
            delete whitelistP[index][whitelist_[i]];
        }
    }
    function getPoolCount() public view returns (uint256) {
        return pools.length;
    }
    function getTxFeeRatio() public view returns (uint256) {
        return config[TxFeeRatio];
    }
    function getMinValueOfBotHolder() public view returns (uint256) {
        return config[MinValueOfBotHolder];
    }
    function getBotToken() public view returns (address) {
        return address(uint160(config[BotToken]));
    }
    function getStakeContract() public view returns (address) {
        return address(uint160(config[StakeContract]));
    }
    modifier checkBotHolder(uint256 index) {
        if (onlyBotHolderP[index]) {
            require(
                IERC20(getBotToken()).balanceOf(msg.sender) >=
                    getMinValueOfBotHolder(),
                "BOT is not enough"
            );
        }
        _;
    }
    modifier isPoolClosed(uint256 index) {
        require(pools[index].closeAt <= block.timestamp, "this pool is not closed");
        _;
    }
    modifier isPoolNotClosed(uint256 index) {
        require(pools[index].closeAt > block.timestamp, "this pool is closed");
        _;
    }
    modifier isPoolNotCreate(address target) {
        if (myCreatedP[target] > 0) {
            revert("a pool has created by this address");
        }
        _;
    }
    modifier isPoolExist(uint256 index) {
        require(index < pools.length, "this pool does not exist");
        _;
    }
}