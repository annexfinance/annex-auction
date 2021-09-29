// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./Access/Governable.sol";
import "./interfaces/IAnnexStake.sol";

contract AnnexFixedSwap is Configurable, ReentrancyGuard {
    using SafeMath for uint;
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using Address for address;
    bytes32 internal constant TxFeeRatio            = bytes32("TxFeeRatio");
    bytes32 internal constant MinValueOfBotHolder   = bytes32("MinValueOfBotHolder");
    bytes32 internal constant BotToken              = bytes32("BotToken");
    bytes32 internal constant StakeContract         = bytes32("StakeContract");
    struct CreateReq {
        string name;
        address token0;
        address token1;
        uint amountTotal0;
        uint amountTotal1;
        uint openAt;
        uint closeAt;
        uint claimAt;
        uint maxAmount1PerWallet;
        bool onlyBot;
        bool enableWhiteList;
    }
    struct Pool {
        string name;
        address payable creator;
        address token0;
        address token1;
        uint amountTotal0;
        uint amountTotal1;
        uint openAt;
        uint closeAt;
        uint claimAt;
        bool enableWhiteList;
    }
    Pool[] public pools;
    mapping(uint => uint) public filledAtP;
    mapping(uint => uint) public amountSwap0P;
    mapping(uint => uint) public amountSwap1P;
    mapping(uint => bool) public onlyBotHolderP;
    mapping(uint => uint) public maxAmount1PerWalletP;
    mapping(address => mapping(uint => bool)) public creatorClaimed;
    mapping(address => mapping(uint => uint)) public myAmountSwapped0;
    mapping(address => mapping(uint => uint)) public myAmountSwapped1;
    mapping(address => mapping(uint => bool)) public myClaimed;
    mapping(uint => mapping(address => bool)) public whitelistP;
    mapping(uint => uint) public txFeeP;
    event Created(uint indexed index, address indexed sender, Pool pool);
    event Swapped(uint indexed index, address indexed sender, uint amount0, uint amount1, uint txFee);
    event Claimed(uint indexed index, address indexed sender, uint amount0, uint txFee);
    event UserClaimed(uint indexed index, address indexed sender, uint amount0);
    function initialize() public initializer {
        config[TxFeeRatio] = 0.005 ether; // 0.5%
        config[MinValueOfBotHolder] = 60 ether;
        config[BotToken] = uint(uint160(0xA9B1Eb5908CfC3cdf91F9B8B3a74108598009096)); // AUCTION
        config[StakeContract] = uint(uint160(0x98945BC69A554F8b129b09aC8AfDc2cc2431c48E));
    }function initialize_rinkeby() public {
        initialize();
        config[BotToken] = uint(uint160(0x5E26FA0FE067d28aae8aFf2fB85Ac2E693BD9EfA)); // AUCTION
        config[StakeContract] = uint(uint160(0xa77A9FcbA2Ae5599e0054369d1655D186020ECE1));
    }function initialize_bsc() public {
        initialize();
        config[BotToken] = uint(uint160(0x1188d953aFC697C031851169EEf640F23ac8529C)); // AUCTION
        config[StakeContract] = uint(uint160(0x1dd665ba1591756aa87157F082F175bDcA9fB91a));
    }function create(CreateReq memory poolReq, address[] memory whitelist_) external nonReentrant {
        uint index = pools.length;
        require(tx.origin == msg.sender, "disallow contract caller");
        require(poolReq.amountTotal0 != 0, "invalid amountTotal0");
        require(poolReq.amountTotal1 != 0, "invalid amountTotal1");
        require(poolReq.openAt >= block.timestamp, "invalid openAt");
        require(poolReq.closeAt > poolReq.openAt, "invalid closeAt");
        require(poolReq.claimAt == 0 || poolReq.claimAt >= poolReq.closeAt, "invalid closeAt");
        require(bytes(poolReq.name).length <= 15, "length of name is too long");
        if (poolReq.maxAmount1PerWallet != 0) {
            maxAmount1PerWalletP[index] = poolReq.maxAmount1PerWallet;
        }
        if (poolReq.onlyBot) {
            onlyBotHolderP[index] = poolReq.onlyBot;
        }
        IERC20  _token0 = IERC20(poolReq.token0);
        uint token0BalanceBefore = _token0.balanceOf(address(this));
        _token0.safeTransferFrom(msg.sender, address(this), poolReq.amountTotal0);
        require(
            _token0.balanceOf(address(this)).sub(token0BalanceBefore) == poolReq.amountTotal0,
            "not support deflationary token"
        );
        if (poolReq.enableWhiteList) {
            require(whitelist_.length > 0, "no whitelist imported");
            _addWhitelist(index, whitelist_);
        }
        Pool memory pool;
        pool.name = poolReq.name;
        pool.creator = payable(msg.sender);
        pool.token0 = poolReq.token0;
        pool.token1 = poolReq.token1;
        pool.amountTotal0 = poolReq.amountTotal0;
        pool.amountTotal1 = poolReq.amountTotal1;
        pool.openAt = poolReq.openAt;
        pool.closeAt = poolReq.closeAt;
        pool.claimAt = poolReq.claimAt;
        pool.enableWhiteList = poolReq.enableWhiteList;
        pools.push(pool);
        emit Created(index, msg.sender, pool);
    }function swap(uint index, uint amount1) external payable
    nonReentrant
    isPoolExist(index)
    isPoolNotClosed(index)
    checkBotHolder(index)
    {
        address payable sender = payable(msg.sender);
        require(tx.origin == msg.sender, "disallow contract caller");
        Pool memory pool = pools[index];
        if (pool.enableWhiteList) {
            require(whitelistP[index][sender], "sender not in whitelist");
        }
        require(pool.openAt <= block.timestamp, "pool not open");
        require(pool.amountTotal1 > amountSwap1P[index], "swap amount is zero");
        uint excessAmount1 = 0;
        uint _amount1 = pool.amountTotal1.sub(amountSwap1P[index]);
        if (_amount1 < amount1) {
            excessAmount1 = amount1.sub(_amount1);
        } else {
            _amount1 = amount1;
        }
        uint amount0 = _amount1.mul(pool.amountTotal0).div(pool.amountTotal1);
        uint _amount0 = pool.amountTotal0.sub(amountSwap0P[index]);
        if (_amount0 > amount0) {
            _amount0 = amount0;
        }
        amountSwap0P[index] = amountSwap0P[index].add(_amount0);
        amountSwap1P[index] = amountSwap1P[index].add(_amount1);
        myAmountSwapped0[sender][index] = myAmountSwapped0[sender][index].add(_amount0);
        if (maxAmount1PerWalletP[index] != 0) {
            require(
                myAmountSwapped1[sender][index].add(_amount1) <= maxAmount1PerWalletP[index],
                "swapped amount of token1 is exceeded maximum allowance"
            );
            myAmountSwapped1[sender][index] = myAmountSwapped1[sender][index].add(_amount1);
        }
        if (pool.amountTotal1 == amountSwap1P[index]) {
            filledAtP[index] = block.timestamp;
        }
        if (pool.token1 == address(0)) {
            require(msg.value == amount1, "invalid amount of ETH");
        } else {
            IERC20(pool.token1).safeTransferFrom(sender, address(this), amount1);
        }
        if (pool.claimAt == 0) {
            if (_amount0 > 0) {
                IERC20(pool.token0).safeTransfer(sender, _amount0);
            }
        }
        if (excessAmount1 > 0) {
            if (pool.token1 == address(0)) {
                sender.transfer(excessAmount1);
            } else {
                IERC20(pool.token1).safeTransfer(sender, excessAmount1);
            }
        }
        uint256 txFee = 0;
        uint256 _actualAmount1 = _amount1;
        if (pool.token1 == address(0)) {
            txFee = _amount1.mul(getTxFeeRatio()).div(1 ether);
            txFeeP[index] += txFee;
            _actualAmount1 = _amount1.sub(txFee);
            pool.creator.transfer(_actualAmount1);
        } else {
            IERC20(pool.token1).safeTransfer(pool.creator, _actualAmount1);
        }
        emit Swapped(index, sender, _amount0, _actualAmount1, txFee);
    }function creatorClaim(uint index) external
    nonReentrant
    isPoolExist(index)
    isPoolClosed(index)
    {
        Pool memory pool = pools[index];
        require(!creatorClaimed[pool.creator][index], "claimed");
        creatorClaimed[pool.creator][index] = true;
        if (txFeeP[index] > 0) {
            if (pool.token1 == address(0)) {
                IAnnexStake(getStakeContract()).depositReward{value: txFeeP[index]}();
            } else {
                IERC20(pool.token1).safeTransfer(getStakeContract(), txFeeP[index]);
            }
        }
        uint unSwapAmount0 = pool.amountTotal0 - amountSwap0P[index];
        if (unSwapAmount0 > 0) {
            IERC20(pool.token0).safeTransfer(pool.creator, unSwapAmount0);
        }
        emit Claimed(index, msg.sender, unSwapAmount0, txFeeP[index]);
    }

    function userClaim(uint index) external
    nonReentrant
    isPoolExist(index)
    isClaimReady(index)
    {
        Pool memory pool = pools[index];
        address sender = msg.sender;
        require(!myClaimed[sender][index], "claimed");
        myClaimed[sender][index] = true;
        if (myAmountSwapped0[sender][index] > 0) {
            IERC20(pool.token0).safeTransfer(msg.sender, myAmountSwapped0[sender][index]);
        }
        emit UserClaimed(index, sender, myAmountSwapped0[sender][index]);
    }function _addWhitelist(uint index, address[] memory whitelist_) private {
        for (uint i = 0; i < whitelist_.length; i++) {
            whitelistP[index][whitelist_[i]] = true;
        }
    }function addWhitelist(uint index, address[] memory whitelist_) external {
        require(owner() == msg.sender || pools[index].creator == msg.sender, "no permission");
        _addWhitelist(index, whitelist_);
    }function removeWhitelist(uint index, address[] memory whitelist_) external {
        require(owner() == msg.sender || pools[index].creator == msg.sender, "no permission");
        for (uint i = 0; i < whitelist_.length; i++) {
            delete whitelistP[index][whitelist_[i]];
        }
    }function getPoolCount() public view returns (uint) {
        return pools.length;
    }function getTxFeeRatio() public view returns (uint) {
        return config[TxFeeRatio];
    }function getMinValueOfBotHolder() public view returns (uint) {
        return config[MinValueOfBotHolder];
    }function getBotToken() public view returns (address) {
        return address(uint160(config[BotToken]));
    }function getStakeContract() public view returns (address) {
        return address(uint160(config[StakeContract]));
    }modifier isPoolClosed(uint index) {
        require(pools[index].closeAt <= block.timestamp, "this pool is not closed");
        _;
    }modifier isPoolNotClosed(uint index) {
        require(pools[index].closeAt > block.timestamp, "this pool is closed");
        _;
    }modifier isClaimReady(uint index) {
        require(pools[index].claimAt != 0, "invalid claim");
        require(pools[index].claimAt <= block.timestamp, "claim not ready");
        _;
    }modifier isPoolExist(uint index) {
        require(index < pools.length, "this pool does not exist");
        _;
    }modifier checkBotHolder(uint index) {
        if (onlyBotHolderP[index]) {
            require(
                IERC20(getBotToken()).balanceOf(msg.sender) >= getMinValueOfBotHolder(),
                "Auction is not enough"
            );
        }
        _;
    }
}