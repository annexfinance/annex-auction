import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/dist/src/signer-with-address";
import { Contract, BigNumber, Wallet } from "ethers";
import { HardhatRuntimeEnvironment } from "hardhat/types";
export interface Price {
  priceNumerator: BigNumber;
  priceDenominator: BigNumber;
}

export interface ReceivedFunds {
  auctioningTokenAmount: BigNumber;
  biddingTokenAmount: BigNumber;
}

export interface OrderResult {
  auctioningToken: string;
  biddingToken: string;
  auctionEndDate: BigNumber;
  orderCancellationEndDate: BigNumber;
  initialAuctionOrder: string;
  minimumBiddingAmountPerOrder: BigNumber;
  interimSumBidAmount: BigNumber;
  interimOrder: string;
  clearingPriceOrder: string;
  volumeClearingPriceOrder: BigNumber;
  feeNumerator: BigNumber;
}

export interface Order {
  sellAmount: BigNumber;
  buyAmount: BigNumber;
  userId: BigNumber;
}

export const queueStartElement =
  "0x0000000000000000000000000000000000000000000000000000000000000001";
export const queueLastElement =
  "0xffffffffffffffffffffffffffffffffffffffff000000000000000000000001";

export function getClearingPriceFromInitialOrder(order: Order): Order {
  return {
    userId: BigNumber.from(0),
    sellAmount: order.buyAmount,
    buyAmount: order.sellAmount,
  };
}
export function encodeOrder(order: Order): string {
  return (
    "0x" +
    order.userId.toHexString().slice(2).padStart(16, "0") +
    order.buyAmount.toHexString().slice(2).padStart(24, "0") +
    order.sellAmount.toHexString().slice(2).padStart(24, "0")
  );
}

export function decodeOrder(bytes: string): Order {
  return {
    userId: BigNumber.from("0x" + bytes.substring(2, 18)),
    sellAmount: BigNumber.from("0x" + bytes.substring(43, 66)),
    buyAmount: BigNumber.from("0x" + bytes.substring(19, 42)),
  };
}

export function toReceivedFunds(result: [BigNumber, BigNumber]): ReceivedFunds {
  return {
    auctioningTokenAmount: result[0],
    biddingTokenAmount: result[1],
  };
}

export async function getInitialOrder(
  annexAuction: Contract,
  auctionId: BigNumber,
): Promise<Order> {
  const auctionDataStruct = await annexAuction.auctionData(auctionId);
  return decodeOrder(auctionDataStruct.initialAuctionOrder);
}

export async function getInterimOrder(
  annexAuction: Contract,
  auctionId: BigNumber,
): Promise<Order> {
  const auctionDataStruct = await annexAuction.auctionData(auctionId);
  return decodeOrder(auctionDataStruct.interimOrder);
}

export async function getAuctionEndTimeStamp(
  annexAuction: Contract,
  auctionId: BigNumber,
): Promise<BigNumber> {
  const auctionDataStruct = await annexAuction.auctionData(auctionId);
  return auctionDataStruct.auctionEndDate;
}

export function hasLowerClearingPrice(order1: Order, order2: Order): number {
  if (
    order1.buyAmount
      .mul(order2.sellAmount)
      .lt(order2.buyAmount.mul(order1.sellAmount))
  )
    return -1;
  if (order1.buyAmount.lt(order2.buyAmount)) return -1;
  if (
    order1.buyAmount
      .mul(order2.sellAmount)
      .eq(order2.buyAmount.mul(order1.sellAmount))
  ) {
    if (order1.userId < order2.userId) return -1;
  }
  return 1;
}

export async function calculateClearingPrice(
  annexAuction: Contract,
  auctionId: BigNumber,
  debug = false,
): Promise<{ clearingOrder: Order; numberOfOrdersToClear: number }> {
  const initialOrder = await getInitialOrder(annexAuction, auctionId);
  const sellOrders = await getAllSellOrders(annexAuction, auctionId);
  sellOrders.sort(function (a: Order, b: Order) {
    return hasLowerClearingPrice(a, b);
  });

  printOrders(sellOrders, false, debug);
  printOrders([initialOrder], true, debug);
  const clearingPriceOrder = findClearingPrice(sellOrders, initialOrder);
  printOrders([clearingPriceOrder], false, debug);
  const interimOrder = await getInterimOrder(annexAuction, auctionId);
  printOrders([interimOrder], false, debug);
  let numberOfOrdersToClear;
  if (
    interimOrder ===
    {
      userId: BigNumber.from(0),
      sellAmount: BigNumber.from(0),
      buyAmount: BigNumber.from(0),
    }
  ) {
    numberOfOrdersToClear = sellOrders.filter((order) =>
      hasLowerClearingPrice(order, clearingPriceOrder),
    ).length;
  } else {
    numberOfOrdersToClear = sellOrders.filter(
      (order) =>
        hasLowerClearingPrice(order, clearingPriceOrder) &&
        hasLowerClearingPrice(interimOrder, order),
    ).length;
  }

  return {
    clearingOrder: clearingPriceOrder,
    numberOfOrdersToClear,
  };
}

function printOrders(orders: Order[], isInitialOrder: boolean, debug = false) {
  const log = debug ? (...a: any) => console.log(...a) : () => {};

  if (isInitialOrder) {
    log("Initial order");
    orders.map((order) => {
      log(
        "selling ",
        order.sellAmount.toString(),
        " for ",
        order.buyAmount.toString(),
        " at price of",
        order.sellAmount.div(order.buyAmount).toString(),
      );
    });
  } else {
    log("Participation orders");
    orders.map((order) => {
      log(
        "selling ",
        order.sellAmount.toString(),
        " for ",
        order.buyAmount.toString(),
        " at price of",
        order.buyAmount.div(order.sellAmount).toString(),
      );
    });
  }
}

export function findClearingPrice(
  sellOrders: Order[],
  initialAuctionOrder: Order,
): Order {
  sellOrders.forEach(function (order, index) {
    if (index > 1) {
      if (!hasLowerClearingPrice(sellOrders[index - 1], order)) {
        throw Error("The orders must be sorted");
      }
    }
  });
  let totalSellVolume = BigNumber.from(0);

  for (const order of sellOrders) {
    totalSellVolume = totalSellVolume.add(order.sellAmount);
    if (
      totalSellVolume
        .mul(order.buyAmount)
        .div(order.sellAmount)
        .gte(initialAuctionOrder.sellAmount)
    ) {
      const coveredBuyAmount = initialAuctionOrder.sellAmount.sub(
        totalSellVolume
          .sub(order.sellAmount)
          .mul(order.buyAmount)
          .div(order.sellAmount),
      );
      const sellAmountClearingOrder = coveredBuyAmount
        .mul(order.sellAmount)
        .div(order.buyAmount);
      if (sellAmountClearingOrder.gt(BigNumber.from(0))) {
        return order;
      } else {
        return {
          userId: BigNumber.from(0),
          buyAmount: initialAuctionOrder.sellAmount,
          sellAmount: totalSellVolume.sub(order.sellAmount),
        };
      }
    }
  }
  // otherwise, clearing price is initialAuctionOrder
  if (totalSellVolume.gt(initialAuctionOrder.buyAmount)) {
    return {
      userId: BigNumber.from(0),
      buyAmount: initialAuctionOrder.sellAmount,
      sellAmount: totalSellVolume,
    };
  } else {
    return {
      userId: BigNumber.from(0),
      buyAmount: initialAuctionOrder.sellAmount,
      sellAmount: initialAuctionOrder.buyAmount,
    };
  }
}

export async function getAllSellOrders(
  annexAuction: Contract,
  auctionId: BigNumber,
): Promise<Order[]> {
  const filterSellOrders = annexAuction.filters.NewSellOrder(
    auctionId,
    null,
    null,
    null,
  );
  const logs = await annexAuction.queryFilter(filterSellOrders, 0, "latest");
  const events = logs.map((log: any) => annexAuction.interface.parseLog(log));
  const sellOrders = events.map((x: any) => {
    const order: Order = {
      userId: x.args[1],
      sellAmount: x.args[3],
      buyAmount: x.args[2],
    };
    return order;
  });

  const filterOrderCancellations = annexAuction.filters.CancellationSellOrder;
  const logsForCancellations = await annexAuction.queryFilter(
    filterOrderCancellations(),
    0,
    "latest",
  );
  const eventsForCancellations = logsForCancellations.map((log: any) =>
    annexAuction.interface.parseLog(log),
  );
  const sellOrdersDeletions = eventsForCancellations.map((x: any) => {
    const order: Order = {
      userId: x.args[1],
      sellAmount: x.args[3],
      buyAmount: x.args[2],
    };
    return order;
  });
  for (const orderDeletion of sellOrdersDeletions) {
    sellOrders.splice(sellOrders.indexOf(orderDeletion), 1);
  }
  return sellOrders;
}

export async function createTokensAndMintAndApprove(
  annexAuction: Contract,
  users: Wallet[],
  hre: HardhatRuntimeEnvironment,
): Promise<{ auctioningToken: Contract; biddingToken: Contract,annexToken:Contract }> {
  const ERC20 = await hre.ethers.getContractFactory("ERC20Mintable");
  const biddingToken = await ERC20.deploy("BT", "BT");
  const auctioningToken = await ERC20.deploy("BT", "BT");
  const annexToken = await ERC20.deploy("BT", "BT");

  for (const user of users) {
    await biddingToken.mint(user.address, BigNumber.from(10).pow(30));
    await biddingToken
      .connect(user)
      .approve(annexAuction.address, BigNumber.from(10).pow(30));

    await auctioningToken.mint(user.address, BigNumber.from(10).pow(30));
    await auctioningToken
    .connect(user)
    .approve(annexAuction.address, BigNumber.from(10).pow(30));

    await annexToken.mint(user.address, BigNumber.from(1000).pow(18));
    await annexToken
    .connect(user)
    .approve(annexAuction.address, BigNumber.from(1000).pow(18));
  }
  return { auctioningToken: auctioningToken, biddingToken: biddingToken,annexToken:annexToken };
}

export async function createDiffTokensAndMintAndApprove(
  annexAuction: Contract,
  users: Wallet[],
  hre: HardhatRuntimeEnvironment,
): Promise<{ auctioningToken: Contract; biddingToken: Contract,annexToken:Contract }> {
  const ERC20 = await hre.ethers.getContractFactory("ERC20Mintable");
  const USDT = await hre.ethers.getContractFactory("CustomToken");
  const biddingToken = await USDT.deploy(hre.ethers.utils.parseEther("10000000"));
  const auctioningToken = await ERC20.deploy("BT", "BT");
  const annexToken = await ERC20.deploy("BT", "BT");

  for (const user of users) {
    await biddingToken.mint(user.address, BigNumber.from(10).pow(12));
    await biddingToken
      .connect(user)
      .approve(annexAuction.address, BigNumber.from(10).pow(11));

    await auctioningToken.mint(user.address, BigNumber.from(10).pow(30));
    await auctioningToken
    .connect(user)
    .approve(annexAuction.address, BigNumber.from(10).pow(30));

    await annexToken.mint(user.address, BigNumber.from(1000).pow(18));
    await annexToken
    .connect(user)
    .approve(annexAuction.address, BigNumber.from(1000).pow(18));
  }
  return { auctioningToken: auctioningToken, biddingToken: biddingToken,annexToken:annexToken };
}

export function toPrice(result: [BigNumber, BigNumber]): Price {
  return {
    priceNumerator: result[0],
    priceDenominator: result[1],
  };
}

export async function placeOrders(
  annexAuction: Contract,
  sellOrders: Order[],
  auctionId: BigNumber,
  hre: HardhatRuntimeEnvironment,
): Promise<void> {
  for (const sellOrder of sellOrders) {
    await annexAuction
      .connect(
        hre.waffle.provider.getWallets()[sellOrder.userId.toNumber() - 1],
      )
      .placeSellOrders(
        auctionId,
        [sellOrder.buyAmount],
        [sellOrder.sellAmount],
        [queueStartElement],
        "0x",
      );
  }
}
