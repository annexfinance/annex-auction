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
  const { depositAndPlaceOrder } = contractNames;
  const { annexAuction, dutchAuction, fixedSwap } = contractNames;


  await deploy(annexAuction, {
    from: deployer,
    gasLimit: 1248779,
    args: [],
    log: true,
    deterministicDeployment: false,
  });
  // const annexAuctionDeployed = await get(annexAuction);

  // await deploy(dutchAuction, {
  //   from: deployer,
  //   gasLimit: 30000000,
  //   args: [],
  //   log: true,
  //   deterministicDeployment: false,
  // });

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
