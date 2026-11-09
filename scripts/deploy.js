const { ethers, artifacts, network } = require("hardhat");
const fs = require("fs");
const path = require("path");

const Role = { Cooperative: 1, Processor: 2, Exporter: 3, Auditor: 4 };
const FAIR_WAGE = 500; // KES per day
const LOCAL_NETWORKS = ["hardhat", "localhost"];

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log(`Deploying to "${network.name}" from ${deployer.address}`);

  const chain = await ethers.deployContract("FairTradeSupplyChain", [FAIR_WAGE]);
  await chain.waitForDeployment();
  const address = await chain.getAddress();
  console.log(`Contract deployed to: ${address}`);

  if (LOCAL_NETWORKS.includes(network.name)) {
    await seedDemoData(chain);
  } else {
    console.log("Public network: no demo data added. Register participants from the dashboard.");
  }

  const { abi } = artifacts.readArtifactSync("FairTradeSupplyChain");
  const outDir = path.join(__dirname, "..", "deployments");
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, `${network.name}.json`), JSON.stringify({ address, abi }, null, 2));
  console.log(`Saved deployments/${network.name}.json`);
}

async function seedDemoData(chain) {
  const [, coop, processor, exporter, auditor] = await ethers.getSigners();

  await (await chain.registerParticipant(coop.address, Role.Cooperative, "Nyeri Coffee Cooperative")).wait();
  await (await chain.registerParticipant(processor.address, Role.Processor, "Karatina Processors")).wait();
  await (await chain.registerParticipant(exporter.address, Role.Exporter, "Mombasa Exporters")).wait();
  await (await chain.registerParticipant(auditor.address, Role.Auditor, "Kenya Fair Trade Auditors")).wait();
  console.log("Registered 4 participants");

  // Batch 1: a fully fair coffee batch
  await (await chain.connect(coop).createBatch("Arabica Coffee AA", "Nyeri, Kenya", 1000)).wait();
  await (await chain.connect(coop).recordWagePayment(1, "W-001", 5, 2500)).wait();
  await (await chain.connect(coop).recordWagePayment(1, "W-002", 5, 2750)).wait();
  await (await chain.connect(coop).handOver(1, processor.address)).wait();
  await (await chain.connect(processor).addStage(1, "Karatina", "Washed and dried")).wait();
  await (await chain.connect(processor).recordWagePayment(1, "W-101", 3, 1800)).wait();
  await (await chain.connect(processor).handOver(1, exporter.address)).wait();
  await (await chain.connect(exporter).addStage(1, "Mombasa Port", "Packed for export")).wait();
  const certHash = ethers.keccak256(ethers.toUtf8Bytes("nyeri-coffee-certificate-2026"));
  await (await chain.connect(auditor).addAudit(1, "bafybeidemocertificate1", certHash, true, "Wages and safety checked")).wait();
  console.log(`Batch 1 verified: ${await chain.isFairTradeVerified(1)}`);

  // Batch 2: a batch with an underpaid worker
  await (await chain.connect(coop).createBatch("Purple Tea", "Kericho, Kenya", 500)).wait();
  await (await chain.connect(coop).recordWagePayment(2, "W-003", 5, 1500)).wait();
  console.log(`Batch 2 verified: ${await chain.isFairTradeVerified(2)}`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});