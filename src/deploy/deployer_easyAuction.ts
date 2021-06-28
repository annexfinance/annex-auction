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

  const { annexAuction } = contractNames;
  
  const { documents} = contractNames;
  

  // const { dutchAuction } = contractNames;

  // const { fixedSwap } = contractNames;

  await deploy(documents, {
    from: deployer,
    gasLimit: 12500000,
    args: [],
    log: true,
    deterministicDeployment: false,
  });
  const documentsDeployed = await get(documents);


  await deploy(annexAuction, {
    from: deployer,
    gasLimit: 12500000,
    args: [documentsDeployed.address],
    log: true,
    deterministicDeployment: false,
  });
  const annexAuctionDeployed = await get(annexAuction);



  // await deploy(dutchAuction, {
  //   from: deployer,
  //   gasLimit: 12500000,
  //   args: [],
  //   log: true,
  //   deterministicDeployment: false,
  // });

  // await deploy(fixedSwap, {
  //   from: deployer,
  //   gasLimit: 12500000,
  //   args: [],
  //   log: true,
  //   deterministicDeployment: false,
  // });

  //  await deploy(wbnb, {
  //   from: deployer,
  //   gasLimit: 12500000,
  //   args: [],
  //   log: true,
  //   deterministicDeployment: false,
  // });
  // const wbnbDeployed = await get(wbnb);

  const weth9Address = await getWETH9Address(hre);

  await deploy(depositAndPlaceOrder, {
    from: deployer,
    gasLimit: 12500000,
    args: [annexAuctionDeployed.address, weth9Address],
    log: true,
    deterministicDeployment: true,
  });


}

export default deployAnnexContract;
