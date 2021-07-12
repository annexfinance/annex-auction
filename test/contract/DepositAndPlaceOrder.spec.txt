/// This file does not represent extensive unit tests, but rather just demonstrates an example
import { expect } from "chai";
import { Contract, BigNumber } from "ethers";
import hre, { ethers, waffle } from "hardhat";
import "@nomiclabs/hardhat-ethers";

import {
  queueStartElement,
  createTokensAndMintAndApprove,
  encodeOrder,
} from "../../src/priceCalculation";

import { createAuctionWithDefaultsAndReturnId } from "./defaultContractInteractions";

describe("DepositAndPlaceOrder - integration tests", async () => {
  const [user_1, user_2] = waffle.provider.getWallets();
  let annexAuction: Contract;
  let depositAndPlaceOrder: Contract;
  let weth9: Contract;
  beforeEach(async () => {
    const AnnexAuction = await ethers.getContractFactory("AnnexBatchAuction");

    annexAuction = await AnnexAuction.deploy();
    const WETH9 = await ethers.getContractFactory("WETH9");
    weth9 = await WETH9.deploy();
    const DepositAndPlaceOrder = await ethers.getContractFactory(
      "DepositAndPlaceOrder",
    );
    depositAndPlaceOrder = await DepositAndPlaceOrder.deploy(
      annexAuction.address,
      weth9.address,
    );
  });
  describe("AccessManager - placing order with the native token", async () => {
    it("integration test: places a new order and checks that tokens were transferred - with whitelisting", async () => {
      const { auctioningToken } = await createTokensAndMintAndApprove(
        annexAuction,
        [user_1, user_2],
        hre,
      );
      const biddingToken = weth9;
      const auctionId: BigNumber = await createAuctionWithDefaultsAndReturnId(
        annexAuction,
        {
          auctioningToken,
          biddingToken,
        },
      );

      const biddingAmount = BigNumber.from(10).pow(18);

      await depositAndPlaceOrder
        .connect(user_2)
        .depositAndPlaceOrder(
          auctionId,
          [BigNumber.from(10).pow(15)],
          [queueStartElement],
          "0x",
          { value: biddingAmount },
        );

      expect(
        await biddingToken.connect(user_2).balanceOf(annexAuction.address),
      ).to.equal(biddingAmount);
      const balanceBeforeOrderPlacementOfUser2 = await biddingToken.balanceOf(
        user_2.address,
      );
      await expect(
        annexAuction.connect(user_2).cancelSellOrders(auctionId, [
          encodeOrder({
            sellAmount: biddingAmount,
            buyAmount: BigNumber.from(10).pow(15),
            userId: BigNumber.from(2),
          }),
        ]),
      )
        .to.emit(biddingToken, "Transfer")
        .withArgs(annexAuction.address, user_2.address, biddingAmount);
      expect(await biddingToken.balanceOf(user_2.address)).to.equal(
        balanceBeforeOrderPlacementOfUser2.add(biddingAmount),
      );
    });
    it("unit test: throws, if sellAmount is too big", async () => {
      const { auctioningToken } = await createTokensAndMintAndApprove(
        annexAuction,
        [user_1, user_2],
        hre,
      );
      const biddingToken = weth9;
      const auctionId: BigNumber = await createAuctionWithDefaultsAndReturnId(
        annexAuction,
        {
          auctioningToken,
          biddingToken,
        },
      );

      const biddingAmount = BigNumber.from(2).pow(98);

      await expect(
        depositAndPlaceOrder
          .connect(user_2)
          .depositAndPlaceOrder(
            auctionId,
            [BigNumber.from(10).pow(15)],
            [queueStartElement],
            "0x",
            { value: biddingAmount },
          ),
      ).to.revertedWith("too much value sent");
    });
    it("unit test: throws, if nativeToken is not supporting deposit", async () => {
      const DepositAndPlaceOrder = await ethers.getContractFactory(
        "DepositAndPlaceOrder",
      );

      const {
        auctioningToken,
        biddingToken,
      } = await createTokensAndMintAndApprove(
        annexAuction,
        [user_1, user_2],
        hre,
      );
      depositAndPlaceOrder = await DepositAndPlaceOrder.deploy(
        annexAuction.address,
        biddingToken.address, //<-- introduces the error
      );
      const biddingTokenCorrect = weth9;
      const auctionId: BigNumber = await createAuctionWithDefaultsAndReturnId(
        annexAuction,
        {
          auctioningToken,
          biddingToken: biddingTokenCorrect,
        },
      );

      const biddingAmount = BigNumber.from(10).pow(18);

      await expect(
        depositAndPlaceOrder
          .connect(user_2)
          .depositAndPlaceOrder(
            auctionId,
            [BigNumber.from(10).pow(15)],
            [queueStartElement],
            "0x",
            { value: biddingAmount },
          ),
      ).to.revertedWith(
        "function selector was not recognized and there's no fallback function",
      );
    });
  });
});
