import { BigNumberish, BytesLike, Contract } from "ethers";

export interface InitiateAuctionInput {
  auctioningToken: Contract;
  biddingToken: Contract;
  orderCancellationEndDate: BigNumberish;
  auctionStartingDate: BigNumberish;
  auctionEndDate: BigNumberish;
  auctionedSellAmount: BigNumberish;
  minBuyAmount: BigNumberish;
  minimumBiddingAmountPerOrder: BigNumberish;
  minFundingThreshold: BigNumberish;
  isAtomicClosureAllowed: boolean;
  allowListManager: BytesLike;
  allowListData: BytesLike;
  router:BigNumberish;
  about:About;

}

export interface About{ 
  website: BytesLike;
  description: BytesLike;
  telegram: BytesLike;
  discord: BytesLike;
  medium: BytesLike;
  twitter: BytesLike;
}