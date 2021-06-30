import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { getWETH9Address } from "../tasks/utils";
import { contractNames } from "../ts/deploy";

const deployAnnexContract: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment,
) {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  const { deploy, get } = deployments;
  const { annexAuction, documents } = contractNames;
  const chainId = await hre.getChainId();

  type GasLimits =  {
    [key: string]: number
  }

  const gasLimits: GasLimits = {
    "3": 30029267, // ropsten
    "42": 12499988, // kovan
    "4": 10000068, // rinkeby
    "97": 30000000, // bsc testnet
  };

  await deploy(documents, {
    from: deployer,
    gasLimit: gasLimits[chainId],
    args: [],
    log: true,
    deterministicDeployment: false,
  });

  const docmentDeployed = await get(documents);

  await deploy(annexAuction, {
    from: deployer,
    gasLimit: 30000001,
    args: [docmentDeployed.address],
    log: true,
    deterministicDeployment: false,
  });

  // const weth9Address = await getWETH9Address(hre);

  // await deploy(depositAndPlaceOrder, {
  //   from: deployer,
  //   gasLimit: 30000000,
  //   args: [annexAuctionDeployed.address, weth9Address],
  //   log: true,
  //   deterministicDeployment: true,
  // });

  // await deploy(fixedSwap, {
  //   from: deployer,
  //   gasLimit: 30000000,
  //   args: [],
  //   log: true,
  //   deterministicDeployment: false,
  // });
};

export default deployAnnexContract;
