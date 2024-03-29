import { Contract, BigNumber } from "ethers";
import { ethers } from "hardhat";
import { InitiateAuctionInput } from "../../src/ts/types";
import { sendTxAndGetReturnValue } from "./utilities";

type PartialAuctionInput = Partial<InitiateAuctionInput> &
  Pick<InitiateAuctionInput, "auctioningToken" | "biddingToken">;

async function createAuctionInputWithDefaults(
  parameters: PartialAuctionInput,
): Promise<unknown[]> {
  const now = (await ethers.provider.getBlock("latest")).timestamp;
  return [
    parameters.auctioningToken.address,
    parameters.biddingToken.address,
    parameters.allowListManager || "0x0000000000000000000000000000000000000000",
    parameters.orderCancellationEndDate || now + 3600,
    parameters.auctionStartingDate || now,
    parameters.auctionEndDate || now + 3600,
    parameters.minimumBiddingAmountPerOrder || 1,
    parameters.minFundingThreshold || 1,
    parameters.auctionedSellAmount || ethers.utils.parseEther("1"),
    parameters.minBuyAmount || ethers.utils.parseEther("1"),
    parameters.isAtomicClosureAllowed || false,
    parameters.allowListData || "0x",
    parameters.about = {
      website: "https://www.link.com/",
      description: "My Batch Auction",
      telegram: "https://telegram.org",
      discord: "https://discord.org",
      medium: "https://medium.org",
      twitter: "https://twitter.org",
    },
  ];
}

export async function createAuctionWithDefaults(
  annexAuction: Contract,
  parameters: PartialAuctionInput,
): Promise<unknown> {
  return annexAuction.initiateAuction([
    ...(await createAuctionInputWithDefaults(parameters)),
  ]);
}

export async function createAuctionWithDefaultsAndReturnId(
  annexAuction: Contract,
  parameters: PartialAuctionInput,
): Promise<BigNumber> {
  return sendTxAndGetReturnValue(
    annexAuction,
    "initiateAuction((address,address,address,uint256,uint256,uint256,uint256,uint256,uint96,uint96,bool,bytes,(string,string,string,string,string,string)))",
    ...(await createAuctionInputWithDefaults(parameters)),
  );
}
