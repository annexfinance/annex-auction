// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./Utils/Governable.sol";
import "./interfaces/IAnnexStake.sol";

contract AnnexFixedSwap is Ownable ,Configurable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using Address for address;

    address public token;
    address public stakeContract;

    bytes32 internal constant TX_FEE_RATIO = bytes32("TxFeeRatio");
    bytes32 internal constant MIN_VALUE_OF_BOT_HOLDER =
        bytes32("MinValueOfAnnexHolder");
    bytes32 internal constant ANNEX_TOKEN = bytes32("AnnexToken");
    bytes32 internal constant STAKE_CONTRACT = bytes32("StakeContract");

    struct CreateReq {
        // pool name
        string name;
        // address of sell token
        address token0;
        // address of buy token
        address token1;
        // total amount of token0
        uint256 amountTotal0;
        // total amount of token1
        uint256 amountTotal1;
        // the timestamp in seconds the pool will open
        uint256 openAt;
        // the timestamp in seconds the pool will be closed
        uint256 closeAt;
        // the delay timestamp in seconds when buyers can claim after pool filled
        uint256 claimAt;
        uint256 maxAmount1PerWallet;
        bool onlyAnnex;
        bool enableWhiteList;
    }

    struct Pool {
        // pool name
        string name;
        // creator of the pool
        address payable creator;
        // address of sell token
        address token0;
        // address of buy token
        address token1;
        // total amount of token0
        uint256 amountTotal0;
        // total amount of token1
        uint256 amountTotal1;
        // the timestamp in seconds the pool will open
        uint256 openAt;
        // the timestamp in seconds the pool will be closed
        uint256 closeAt;
        // the delay timestamp in seconds when buyers can claim after pool filled
        uint256 claimAt;
        // whether or not whitelist is enable
        bool enableWhiteList;
    }

    Pool[] public pools;

    // pool index => the timestamp which the pool filled at
    mapping(uint256 => uint256) public filledAtP;
    // pool index => swap amount of token0
    mapping(uint256 => uint256) public amountSwap0P;
    // pool index => swap amount of token1
    mapping(uint256 => uint256) public amountSwap1P;
    // pool index => the swap pool only allow BOT holder to take part in
    mapping(uint256 => bool) public onlyAnnexHolderP;
    // pool index => maximum swap amount1 per wallet, if the value is not set, the default value is zero
    mapping(uint256 => uint256) public maxAmount1PerWalletP;
    // team address => pool index => whether or not creator's pool has been claimed
    mapping(address => mapping(uint256 => bool)) public creatorClaimed;
    // user address => pool index => swapped amount of token0
    mapping(address => mapping(uint256 => uint256)) public myAmountSwapped0;
    // user address => pool index => swapped amount of token1
    mapping(address => mapping(uint256 => uint256)) public myAmountSwapped1;
    // user address => pool index => whether or not my pool has been claimed
    mapping(address => mapping(uint256 => bool)) public myClaimed;

    // pool index => account => whether or not in white list
    mapping(uint256 => mapping(address => bool)) public whitelistP;
    // pool index => transaction fee
    mapping(uint256 => uint256) public txFeeP;

    event Created(uint256 indexed index, address indexed sender, Pool pool);
    event Swapped(
        uint256 indexed index,
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        uint256 txFee
    );
    event Claimed(
        uint256 indexed index,
        address indexed sender,
        uint256 amount0,
        uint256 txFee
    );
    event UserClaimed(
        uint256 indexed index,
        address indexed sender,
        uint256 amount0
    );
    

    function initialize() public {
        config[TX_FEE_RATIO] = 0.015 ether;
        config[MIN_VALUE_OF_BOT_HOLDER] = 60 ether;

        config[ANNEX_TOKEN] = uint256(token);
        config[STAKE_CONTRACT] = uint256(
            stakeContract
        );
    }

    function setAddresses(address _token,address _stakeContract) external {

    }

    function initialize_rinkeby() public {
        initialize();

        config[ANNEX_TOKEN] = uint256(token);
        config[STAKE_CONTRACT] = uint256(
            stakeContract
        );
    }

    function create(CreateReq memory poolReq, address[] memory whitelist_)
        external
        nonReentrant
    {
        uint256 index = pools.length;
        require(tx.origin == msg.sender, "disallow contract caller");
        require(poolReq.amountTotal0 != 0, "invalid amountTotal0");
        require(poolReq.amountTotal1 != 0, "invalid amountTotal1");
        require(poolReq.openAt >= now, "invalid openAt");
        require(poolReq.closeAt > poolReq.openAt, "invalid closeAt");
        require(
            poolReq.claimAt == 0 || poolReq.claimAt >= poolReq.closeAt,
            "invalid closeAt"
        );
        require(bytes(poolReq.name).length <= 15, "length of name is too long");

        if (poolReq.maxAmount1PerWallet != 0) {
            maxAmount1PerWalletP[index] = poolReq.maxAmount1PerWallet;
        }
        if (poolReq.onlyAnnex) {
            onlyAnnexHolderP[index] = poolReq.onlyAnnex;
        }

        // transfer amount of token0 to this contract
        IERC20 _token0 = IERC20(poolReq.token0);
        uint256 token0BalanceBefore = _token0.balanceOf(address(this));
        _token0.safeTransferFrom(
            msg.sender,
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
        pool.creator = msg.sender;
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
    }

    function swap(uint256 index, uint256 amount1)
        external
        payable
        nonReentrant
        isPoolExist(index)
        isPoolNotClosed(index)
        checkAnnexHolder(index)
    {
        address payable sender = msg.sender;
        require(tx.origin == msg.sender, "disallow contract caller");
        Pool memory pool = pools[index];

        if (pool.enableWhiteList) {
            require(whitelistP[index][sender], "sender not in whitelist");
        }
        require(pool.openAt <= now, "pool not open");
        require(pool.amountTotal1 > amountSwap1P[index], "swap amount is zero");

        // check if amount1 is exceeded
        uint256 excessAmount1 = 0;
        uint256 _amount1 = pool.amountTotal1.sub(amountSwap1P[index]);
        if (_amount1 < amount1) {
            excessAmount1 = amount1.sub(_amount1);
        } else {
            _amount1 = amount1;
        }

        // check if amount0 is exceeded
        uint256 amount0 = _amount1.mul(pool.amountTotal0).div(
            pool.amountTotal1
        );
        uint256 _amount0 = pool.amountTotal0.sub(amountSwap0P[index]);
        if (_amount0 > amount0) {
            _amount0 = amount0;
        }

        amountSwap0P[index] = amountSwap0P[index].add(_amount0);
        amountSwap1P[index] = amountSwap1P[index].add(_amount1);
        myAmountSwapped0[sender][index] = myAmountSwapped0[sender][index].add(
            _amount0
        );
        // check if swapped amount of token1 is exceeded maximum allowance
        if (maxAmount1PerWalletP[index] != 0) {
            require(
                myAmountSwapped1[sender][index].add(_amount1) <=
                    maxAmount1PerWalletP[index],
                "swapped amount of token1 is exceeded maximum allowance"
            );
            myAmountSwapped1[sender][index] = myAmountSwapped1[sender][index]
            .add(_amount1);
        }

        if (pool.amountTotal1 == amountSwap1P[index]) {
            filledAtP[index] = now;
        }

        // transfer amount of token1 to this contract
        if (pool.token1 == address(0)) {
            require(msg.value == amount1, "invalid amount of ETH");
        } else {
            IERC20(pool.token1).safeTransferFrom(
                sender,
                address(this),
                amount1
            );
        }

        if (pool.claimAt == 0) {
            if (_amount0 > 0) {
                // send token0 to sender
                IERC20(pool.token0).safeTransfer(sender, _amount0);
            }
        }
        if (excessAmount1 > 0) {
            // send excess amount of token1 back to sender
            if (pool.token1 == address(0)) {
                sender.transfer(excessAmount1);
            } else {
                IERC20(pool.token1).safeTransfer(sender, excessAmount1);
            }
        }

        // send token1 to creator
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
    }

    function creatorClaim(uint256 index)
        external
        nonReentrant
        isPoolExist(index)
        isPoolClosed(index)
    {
        Pool memory pool = pools[index];
        require(!creatorClaimed[pool.creator][index], "claimed");
        creatorClaimed[pool.creator][index] = true;

        if (txFeeP[index] > 0) {
            if (pool.token1 == address(0)) {
                // deposit transaction fee to staking contract
                IAnnexStake(getStakeContract()).depositReward{
                    value: txFeeP[index]
                }();
            }
        }

        uint256 unSwapAmount0 = pool.amountTotal0 - amountSwap0P[index];
        if (unSwapAmount0 > 0) {
            IERC20(pool.token0).safeTransfer(pool.creator, unSwapAmount0);
        }

        emit Claimed(index, msg.sender, unSwapAmount0, txFeeP[index]);
    }

    function userClaim(uint256 index)
        external
        nonReentrant
        isPoolExist(index)
        isClaimReady(index)
    {
        Pool memory pool = pools[index];
        address sender = msg.sender;
        require(!myClaimed[sender][index], "claimed");
        myClaimed[sender][index] = true;
        if (myAmountSwapped0[sender][index] > 0) {
            // send token0 to sender
            IERC20(pool.token0).safeTransfer(
                msg.sender,
                myAmountSwapped0[sender][index]
            );
        }
        emit UserClaimed(index, sender, myAmountSwapped0[sender][index]);
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
        return config[TX_FEE_RATIO];
    }

    function getMinValueOfAnnexHolder() public view returns (uint256) {
        return config[MIN_VALUE_OF_BOT_HOLDER];
    }

    function getAnnexToken() public view returns (address) {
        return address(config[ANNEX_TOKEN]);
    }

    function getStakeContract() public view returns (address) {
        return address(config[STAKE_CONTRACT]);
    }

    modifier isPoolClosed(uint256 index) {
        require(pools[index].closeAt <= now, "this pool is not closed");
        _;
    }

    modifier isPoolNotClosed(uint256 index) {
        require(pools[index].closeAt > now, "this pool is closed");
        _;
    }

    modifier isClaimReady(uint256 index) {
        require(pools[index].claimAt != 0, "invalid claim");
        require(pools[index].claimAt <= now, "claim not ready");
        _;
    }

    modifier isPoolExist(uint256 index) {
        require(index < pools.length, "this pool does not exist");
        _;
    }

    modifier checkAnnexHolder(uint256 index) {
        if (onlyAnnexHolderP[index]) {
            require(
                IERC20(getAnnexToken()).balanceOf(msg.sender) >=
                    getMinValueOfAnnexHolder(),
                "Auction is not enough"
            );
        }
        _;
    }
}
