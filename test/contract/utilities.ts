import { BigNumber, Contract,Wallet } from "ethers";

import { ethers } from "hardhat";
import { encodeOrder, Order } from "../../src/priceCalculation";
import routerAbi from "./Externals/router.json";
import {routerBytecode} from "./Externals/router_bytecode";
import factoryAbi from "./Externals/factory.json";
import {factoryBytecode} from "./Externals/factory_bytecode";

export const MAGIC_VALUE_FROM_ALLOW_LIST_VERIFIER_INTERFACE = "0x19a05a7e";

export async function closeAuction(
  instance: Contract,
  auctionId: BigNumber,
): Promise<void> {
  const time_remaining = (
    await instance.getSecondsRemainingInBatch(auctionId)
  ).toNumber();
  await increaseTime(time_remaining + 10);
}

export async function claimFromAllOrders(
  annexAuction: Contract,
  auctionId: BigNumber,
  orders: Order[],
): Promise<void> {
  for (const order of orders) {
    await annexAuction.claimFromParticipantOrder(auctionId, [
      encodeOrder(order),
    ]);
  }
}

export async function setupRouter(signer:Wallet):Promise<{_router:Contract,_factory:Contract}>{
  const PancakeFactory = await ethers.getContractFactory(factoryAbi,factoryBytecode,signer);
  const _factory = await PancakeFactory.deploy(signer.address);
  const WBNB = await ethers.getContractFactory("WBNB");
  const wbnb = await WBNB.deploy();
  const PancakeRouter = await ethers.getContractFactory(routerAbi,routerBytecode,signer);
  const _router = await PancakeRouter.deploy(_factory.address,wbnb.address);
  return {_router,_factory};
}

export async function increaseTime(duration: number): Promise<void> {
  ethers.provider.send("evm_increaseTime", [duration]);
  ethers.provider.send("evm_mine", []);
}

export async function sendTxAndGetReturnValue<T>(
  contract: Contract,
  fnName: string,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  ...args: any[]
): Promise<T> {
  const result = await contract.callStatic[fnName]([...args]);
  await contract.functions[fnName]([...args]);
  return result;
}

export async function setPrequistes(contract:Contract,annex:Contract,router:Contract,signer:Wallet,treasury:Wallet):Promise<void>{
  await contract.connect(signer).setAnnexAddress(annex.address);
  await contract.connect(signer).setTreasury(treasury.address);
  await contract.connect(signer).setRouters([router.address]);
}