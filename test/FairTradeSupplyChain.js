const { loadFixture } = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { ethers } = require("hardhat");

const Role = { Cooperative: 1, Processor: 2, Exporter: 3, Auditor: 4 };
const FAIR_WAGE = 500; // KES per day
const CERT_HASH = ethers.keccak256(ethers.toUtf8Bytes("fairtrade-certificate-2026"));
const CID = "bafybeigdyrexamplecid";

describe("FairTradeSupplyChain", function () {
  async function deployFixture() {
    const [owner, coop, processor, exporter, auditor, stranger] = await ethers.getSigners();
    const chain = await ethers.deployContract("FairTradeSupplyChain", [FAIR_WAGE]);

    await chain.registerParticipant(coop.address, Role.Cooperative, "Nyeri Coffee Cooperative");
    await chain.registerParticipant(processor.address, Role.Processor, "Karatina Processors");
    await chain.registerParticipant(exporter.address, Role.Exporter, "Mombasa Exporters");
    await chain.registerParticipant(auditor.address, Role.Auditor, "Fair Trade Auditor");

    return { chain, owner, coop, processor, exporter, auditor, stranger };
  }

  async function batchFixture() {
    const f = await deployFixture();
    await f.chain.connect(f.coop).createBatch("Arabica Coffee AA", "Nyeri, Kenya", 1000);
    return f;
  }

  describe("Deployment and roles", function () {
    it("sets the owner and fair daily wage", async function () {
      const { chain, owner } = await loadFixture(deployFixture);
      expect(await chain.owner()).to.equal(owner.address);
      expect(await chain.fairDailyWageKES()).to.equal(FAIR_WAGE);
    });

    it("only the owner can register participants", async function () {
      const { chain, stranger } = await loadFixture(deployFixture);
      await expect(
        chain.connect(stranger).registerParticipant(stranger.address, Role.Cooperative, "Fake Co-op")
      ).to.be.revertedWithCustomError(chain, "NotOwner");
    });

    it("keeps a list of registered participants", async function () {
      const { chain, coop, processor, exporter, auditor } = await loadFixture(deployFixture);
      const list = await chain.getParticipants();
      expect([...list]).to.deep.equal([coop.address, processor.address, exporter.address, auditor.address]);
    });
  });

  describe("Batches and stages", function () {
    it("a cooperative can create a batch", async function () {
      const { chain, coop } = await loadFixture(deployFixture);
      await expect(chain.connect(coop).createBatch("Arabica Coffee AA", "Nyeri, Kenya", 1000))
        .to.emit(chain, "BatchCreated")
        .withArgs(1, "Arabica Coffee AA", coop.address);

      const stages = await chain.getStages(1);
      expect(stages.length).to.equal(1);
      expect(stages[0].description).to.equal("Harvested");
    });

    it("a non-cooperative cannot create a batch", async function () {
      const { chain, processor } = await loadFixture(deployFixture);
      await expect(
        chain.connect(processor).createBatch("Coffee", "Nyeri", 100)
      ).to.be.revertedWithCustomError(chain, "NotAuthorised");
    });

    it("tracks the full journey from farm to exporter", async function () {
      const { chain, coop, processor, exporter } = await loadFixture(batchFixture);

      await chain.connect(coop).handOver(1, processor.address);
      await chain.connect(processor).addStage(1, "Karatina", "Washed and dried");
      await chain.connect(processor).handOver(1, exporter.address);
      await chain.connect(exporter).addStage(1, "Mombasa Port", "Packed for export");

      const stages = await chain.getStages(1);
      expect(stages.length).to.equal(3);
      expect(stages[2].description).to.equal("Packed for export");
      expect((await chain.getBatch(1)).currentHolder).to.equal(exporter.address);
    });

    it("only the current holder can add a stage", async function () {
      const { chain, processor } = await loadFixture(batchFixture);
      await expect(
        chain.connect(processor).addStage(1, "Karatina", "Washed")
      ).to.be.revertedWithCustomError(chain, "NotCurrentHolder");
    });

    it("a batch cannot be handed to an auditor", async function () {
      const { chain, coop, auditor } = await loadFixture(batchFixture);
      await expect(
        chain.connect(coop).handOver(1, auditor.address)
      ).to.be.revertedWithCustomError(chain, "InvalidInput");
    });

    it("reading a batch that doesn't exist fails", async function () {
      const { chain } = await loadFixture(deployFixture);
      await expect(chain.getBatch(99)).to.be.revertedWithCustomError(chain, "BatchNotFound");
    });
  });

  describe("Wages", function () {
    it("marks a wage at or above the fair rate as fair", async function () {
      const { chain, coop } = await loadFixture(batchFixture);
      await expect(chain.connect(coop).recordWagePayment(1, "W-001", 5, 2500))
        .to.emit(chain, "WageRecorded")
        .withArgs(1, "W-001", 2500, true);
    });

    it("marks a wage below the fair rate as unfair", async function () {
      const { chain, coop } = await loadFixture(batchFixture);
      await chain.connect(coop).recordWagePayment(1, "W-002", 5, 2000);
      const wages = await chain.getWages(1);
      expect(wages[0].meetsFairWage).to.equal(false);
    });
  });

  describe("Audits", function () {
    it("an auditor can add a certificate and anyone can verify it", async function () {
      const { chain, auditor } = await loadFixture(batchFixture);
      await chain.connect(auditor).addAudit(1, CID, CERT_HASH, true, "Wages and safety checked");

      expect(await chain.verifyDocument(1, 0, CERT_HASH)).to.equal(true);
      const fakeHash = ethers.keccak256(ethers.toUtf8Bytes("tampered-certificate"));
      expect(await chain.verifyDocument(1, 0, fakeHash)).to.equal(false);
    });

    it("a non-auditor cannot add an audit", async function () {
      const { chain, coop } = await loadFixture(batchFixture);
      await expect(
        chain.connect(coop).addAudit(1, CID, CERT_HASH, true, "Self-certified")
      ).to.be.revertedWithCustomError(chain, "NotAuthorised");
    });
  });

  describe("Fair Trade verification", function () {
    it("is verified with fair wages and a passed audit", async function () {
      const { chain, coop, auditor } = await loadFixture(batchFixture);
      await chain.connect(coop).recordWagePayment(1, "W-001", 5, 2500);
      await chain.connect(auditor).addAudit(1, CID, CERT_HASH, true, "Passed");
      expect(await chain.isFairTradeVerified(1)).to.equal(true);
    });

    it("is not verified if any wage is unfair", async function () {
      const { chain, coop, auditor } = await loadFixture(batchFixture);
      await chain.connect(coop).recordWagePayment(1, "W-001", 5, 2500);
      await chain.connect(coop).recordWagePayment(1, "W-002", 5, 1000);
      await chain.connect(auditor).addAudit(1, CID, CERT_HASH, true, "Passed");
      expect(await chain.isFairTradeVerified(1)).to.equal(false);
    });

    it("is not verified without an audit", async function () {
      const { chain, coop } = await loadFixture(batchFixture);
      await chain.connect(coop).recordWagePayment(1, "W-001", 5, 2500);
      expect(await chain.isFairTradeVerified(1)).to.equal(false);
    });
  });
});