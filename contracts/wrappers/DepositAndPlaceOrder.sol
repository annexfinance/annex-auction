// SPDX-License-Identifier: MIT
pragma solidity >=0.6.8;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../AnnexBatchAuction.sol";
import "../interfaces/IWETH.sol";

contract DepositAndPlaceOrder {
    AnnexBatchAuction public immutable annexAuction;
    IWETH public immutable nativeTokenWrapper;

    constructor(address annexAuctionAddress, address _nativeTokenWrapper)
        public
    {
        nativeTokenWrapper = IWETH(_nativeTokenWrapper);
        annexAuction = AnnexBatchAuction(annexAuctionAddress);
        IERC20(_nativeTokenWrapper).approve(annexAuctionAddress, uint256(-1));
    }

    function depositAndPlaceOrder(
        uint256 auctionId,
        uint96[] memory _minBuyAmounts,
        bytes32[] memory _prevSellOrders,
        bytes calldata allowListCallData
    ) external payable returns (uint64 userId) {
        uint96[] memory sellAmounts = new uint96[](1);
        require(msg.value < 2**96, "too much value sent");
        nativeTokenWrapper.deposit{value: msg.value}();
        sellAmounts[0] = uint96(msg.value);
        return
            annexAuction.placeSellOrdersOnBehalf(
                auctionId,
                _minBuyAmounts,
                sellAmounts,
                _prevSellOrders,
                allowListCallData,
                msg.sender
            );
    }
}
