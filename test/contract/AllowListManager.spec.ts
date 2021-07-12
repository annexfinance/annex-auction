/// This file does not represent extensive unit tests, but rather just demonstrates an example
import { expect } from "chai";
import { deployMockContract } from "ethereum-waffle";
import { Contract, BigNumber } from "ethers";
import hre, { artifacts, ethers, waffle } from "hardhat";
import "@nomiclabs/hardhat-ethers";

import {
  queueStartElement,
  createTokensAndMintAndApprove,
} from "../../src/priceCalculation";
import { domain } from "../../src/tasks/utils";

import { createAuctionWithDefaultsAndReturnId } from "./defaultContractInteractions";
import {
  MAGIC_VALUE_FROM_ALLOW_LIST_VERIFIER_INTERFACE,
  setPrequistes,
  setupRouter
} from "./utilities";

describe("AccessManager - integration tests", async () => {
  const [user_1, user_2, treasury] = waffle.provider.getWallets();
  let annexAuction: Contract;
  let router: Contract;
  let allowListManager: Contract;
  let testDomain: any;
  beforeEach(async () => {
    const AnnexAuction = await ethers.getContractFactory(
      "AnnexBatchAuction",
      user_1,
    );

    annexAuction = await AnnexAuction.deploy();
    const AllowListManger = await ethers.getContractFactory(
      "AllowListOffChainManaged",
    );
    allowListManager = await AllowListManger.deploy();
    const { chainId } = await ethers.provider.getNetwork();
    testDomain = domain(chainId, allowListManager.address);

    router = await (await setupRouter(user_1))._router;
    annexAuction.setRouters([router.address]);
  });
  describe("AccessManager - placing order in annexAuction with auctioneer signature", async () => {
    it("integration test: places a new order and checks that tokens were transferred - with whitelisting", async () => {
      const { auctioningToken, biddingToken } =
        await createTokensAndMintAndApprove(
          annexAuction,
          [user_1, user_2],
          hre,
        );
      await auctioningToken.mint(user_1.address, BigNumber.from(100).pow(18));

      await setPrequistes(annexAuction, auctioningToken,router, user_1, treasury);
      const auctionId: BigNumber = await createAuctionWithDefaultsAndReturnId(
        annexAuction,
        {
          auctioningToken,
          biddingToken,
          allowListManager: allowListManager.address,
          allowListData: ethers.utils.defaultAbiCoder.encode(
            ["address"],
            [user_1.address],
          ),
          router:0
        },
      );
      const auctioneerMessage = ethers.utils.keccak256(
        ethers.utils.defaultAbiCoder.encode(
          ["bytes32", "address", "uint256"],
          [
            ethers.utils._TypedDataEncoder.hashDomain(testDomain),
            user_2.address,
            auctionId,
          ],
        ),
      );
      const auctioneerSignature = await user_1.signMessage(
        ethers.utils.arrayify(auctioneerMessage),
      );
      const sig = ethers.utils.splitSignature(auctioneerSignature);
      const auctioneerSignatureEncoded = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "bytes32", "bytes32"],
        [sig.v, sig.r, sig.s],
      );

      const balanceBeforeOrderPlacement = await biddingToken
        .connect(user_2)
        .balanceOf(user_1.address);
      const sellAmount = ethers.utils.parseEther("1").add(1);
      const buyAmount = ethers.utils.parseEther("1");

      await annexAuction
        .connect(user_2)
        .placeSellOrders(
          auctionId,
          [buyAmount, buyAmount],
          [sellAmount, sellAmount.add(1)],
          [queueStartElement, queueStartElement],
          auctioneerSignatureEncoded,
        );
      const transferredbiddingTokenAmount = sellAmount.add(sellAmount.add(1));
      const annexAddress = await annexAuction.annexToken();
      const treasuryAddress = await annexAuction.treasury();
      expect(auctioningToken.address).to.equal(annexAddress);
      expect(treasury.address).to.equal(treasuryAddress);

      expect(
        await biddingToken.connect(user_2).balanceOf(annexAuction.address),
      ).to.equal(transferredbiddingTokenAmount);
      expect(
        await biddingToken.connect(user_2).balanceOf(user_2.address),
      ).to.equal(
        balanceBeforeOrderPlacement.sub(transferredbiddingTokenAmount),
      );
    });

    it("integration test: places a new order and checks that allowListing prevents the tx", async () => {
      const AllowListManager = await ethers.getContractFactory(
        "AllowListOffChainManaged",
      );

      const allowListManager = await AllowListManager.deploy();
      const { auctioningToken, biddingToken } =
        await createTokensAndMintAndApprove(
          annexAuction,
          [user_1, user_2],
          hre,
        );
        await setPrequistes(annexAuction, auctioningToken,router, user_1, treasury);
      const auctionId: BigNumber = await createAuctionWithDefaultsAndReturnId(
        annexAuction,
        {
          auctioningToken,
          biddingToken,
          allowListManager: allowListManager.address,
          allowListData: ethers.utils.defaultAbiCoder.encode(
            ["address"],
            [user_1.address],
          ),
          router:0
        },
      );

      const { chainId } = await ethers.provider.getNetwork();
      const testDomain = domain(chainId, allowListManager.address);
      const auctioneerMessage = ethers.utils.keccak256(
        ethers.utils.defaultAbiCoder.encode(
          ["bytes32", "address", "uint256"],
          [
            ethers.utils._TypedDataEncoder.hashDomain(testDomain),
            user_2.address,
            auctionId,
          ],
        ),
      );
      // Signature will come from a wrong user: user_2 != allowListSigner;
      const auctioneerSignature = await user_2.signMessage(
        ethers.utils.arrayify(auctioneerMessage),
      );
      const sig = ethers.utils.splitSignature(auctioneerSignature);
      const auctioneerSignatureEncoded = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "bytes32", "bytes32"],
        [sig.v, sig.r, sig.s],
      );

      const sellAmount = ethers.utils.parseEther("1").add(1);
      const buyAmount = ethers.utils.parseEther("1");
      await expect(
        annexAuction
          .connect(user_2)
          .placeSellOrders(
            auctionId,
            [buyAmount, buyAmount],
            [sellAmount, sellAmount.add(1)],
            [queueStartElement, queueStartElement],
            auctioneerSignatureEncoded,
          ),
      ).to.be.revertedWith("NOT_ALLOWED");
    });
  });
});

describe("AccessManager - unit tests", async () => {
  const [user_1, user_2] = waffle.provider.getWallets();
  let allowListManager: Contract;
  let testDomain: any;
  beforeEach(async () => {
    const AllowListManger = await ethers.getContractFactory(
      "AllowListOffChainManaged",
    );
    allowListManager = await AllowListManger.deploy();
    const { chainId } = await ethers.provider.getNetwork();
    testDomain = domain(chainId, allowListManager.address);
  });
  describe("domainSeparator", () => {
    it("should have an EIP-712 domain separator", async () => {
      expect(await allowListManager.domainSeparator()).to.equal(
        ethers.utils._TypedDataEncoder.hashDomain(testDomain),
      );
    });
  });
  describe("AccessManager", () => {
    it("should return 0, if auctionId is incorrect", async () => {
      const signer = user_1;
      const annexAuction = await artifacts.readArtifact("AnnexBatchAuction");
      const mockContract = await deployMockContract(user_1, annexAuction.abi);
      await mockContract.mock.auctionAccessData.returns(
        ethers.utils.defaultAbiCoder.encode(["address"], [signer.address]),
      );
      const auctionId = 1;
      const wrongAuctionId = 2;
      const auctioneerMessage = ethers.utils.keccak256(
        ethers.utils.defaultAbiCoder.encode(
          ["bytes32", "address", "uint256"],
          [
            ethers.utils._TypedDataEncoder.hashDomain(testDomain),
            user_2.address,
            wrongAuctionId,
          ],
        ),
      );
      const auctioneerSignature = await signer.signMessage(
        ethers.utils.arrayify(auctioneerMessage),
      );
      const sig = ethers.utils.splitSignature(auctioneerSignature);
      const auctioneerSignatureEncoded = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "bytes32", "bytes32"],
        [sig.v, sig.r, sig.s],
      );
      expect(
        await allowListManager.isAllowedBy(
          user_2.address,
          auctionId,
          mockContract.address,
          auctioneerSignatureEncoded,
        ),
      ).to.equal("0x00000000");
    });
    it("should return 0, if allowListSigner is incorrect", async () => {
      const annexAuction = await artifacts.readArtifact("AnnexBatchAuction");
      const signer = user_2;
      const mockContract = await deployMockContract(user_1, annexAuction.abi);
      await mockContract.mock.auctionAccessData.returns(
        ethers.utils.defaultAbiCoder.encode(["address"], [signer.address]),
      );
      const auctionId = 1;
      const wrongSigner = user_1;
      const auctioneerMessage = ethers.utils.keccak256(
        ethers.utils.defaultAbiCoder.encode(
          ["bytes32", "address", "uint256"],
          [
            ethers.utils._TypedDataEncoder.hashDomain(testDomain),
            user_2.address,
            auctionId,
          ],
        ),
      );
      const auctioneerSignature = await wrongSigner.signMessage(
        ethers.utils.arrayify(auctioneerMessage),
      );
      const sig = ethers.utils.splitSignature(auctioneerSignature);
      const auctioneerSignatureEncoded = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "bytes32", "bytes32"],
        [sig.v, sig.r, sig.s],
      );
      expect(
        await allowListManager.isAllowedBy(
          user_2.address,
          auctionId,
          mockContract.address,
          auctioneerSignatureEncoded,
        ),
      ).to.equal("0x00000000");
    });
    it("should return 0, if domain separator is incorrect", async () => {
      const signer = user_2;
      const annexAuction = await artifacts.readArtifact("AnnexBatchAuction");
      const mockContract = await deployMockContract(user_1, annexAuction.abi);
      await mockContract.mock.auctionAccessData.returns(
        ethers.utils.defaultAbiCoder.encode(["address"], [signer.address]),
      );
      const auctionId = 1;
      const wrongSigner = user_1;
      const auctioneerMessage = ethers.utils.keccak256(
        ethers.utils.defaultAbiCoder.encode(
          ["bytes32", "address", "uint256"],
          [
            ethers.utils._TypedDataEncoder.hashDomain(
              domain(0, allowListManager.address),
            ),
            user_2.address,
            auctionId,
          ],
        ),
      );
      const auctioneerSignature = await wrongSigner.signMessage(
        ethers.utils.arrayify(auctioneerMessage),
      );
      const sig = ethers.utils.splitSignature(auctioneerSignature);
      const auctioneerSignatureEncoded = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "bytes32", "bytes32"],
        [sig.v, sig.r, sig.s],
      );
      expect(
        await allowListManager.isAllowedBy(
          user_2.address,
          auctionId,
          mockContract.address,
          auctioneerSignatureEncoded,
        ),
      ).to.equal("0x00000000");
    });
    it("should return 0, if signature is incorrect", async () => {
      const signer = user_2;
      const annexAuction = await artifacts.readArtifact("AnnexBatchAuction");
      const mockContract = await deployMockContract(user_1, annexAuction.abi);
      await mockContract.mock.auctionAccessData.returns(
        ethers.utils.defaultAbiCoder.encode(["address"], [signer.address]),
      );
      const auctionId = 1;
      const auctioneerMessage = ethers.utils.keccak256(
        ethers.utils.defaultAbiCoder.encode(
          ["bytes32", "address", "uint256"],
          [
            ethers.utils._TypedDataEncoder.hashDomain(testDomain),
            user_2.address,
            auctionId,
          ],
        ),
      );
      const auctioneerSignature = await signer.signMessage(
        ethers.utils.arrayify(auctioneerMessage),
      );
      const sig = ethers.utils.splitSignature(auctioneerSignature);
      const auctioneerSignatureEncoded = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "bytes32", "bytes32"],
        [sig.v + 1, sig.r, sig.s], // < error in signature
      );
      expect(
        await allowListManager.isAllowedBy(
          user_2.address,
          auctionId,
          mockContract.address,
          auctioneerSignatureEncoded,
        ),
      ).to.equal("0x00000000");
    });
    it("should return magic value, if everything is valid", async () => {
      const signer = user_2;
      const annexAuction = await artifacts.readArtifact("AnnexBatchAuction");
      const mockContract = await deployMockContract(user_1, annexAuction.abi);
      await mockContract.mock.auctionAccessData.returns(
        ethers.utils.defaultAbiCoder.encode(["address"], [signer.address]),
      );
      const auctionId = 1;
      const auctioneerMessage = ethers.utils.keccak256(
        ethers.utils.defaultAbiCoder.encode(
          ["bytes32", "address", "uint256"],
          [
            ethers.utils._TypedDataEncoder.hashDomain(testDomain),
            user_2.address,
            auctionId,
          ],
        ),
      );
      const auctioneerSignature = await signer.signMessage(
        ethers.utils.arrayify(auctioneerMessage),
      );
      const sig = ethers.utils.splitSignature(auctioneerSignature);
      const auctioneerSignatureEncoded = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "bytes32", "bytes32"],
        [sig.v, sig.r, sig.s],
      );
      expect(
        await allowListManager.isAllowedBy(
          user_2.address,
          auctionId,
          mockContract.address,
          auctioneerSignatureEncoded,
        ),
      ).to.equal(MAGIC_VALUE_FROM_ALLOW_LIST_VERIFIER_INTERFACE);
    });
  });
});
