import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);

  // Uniswap V3 SwapRouter02
  // Sepolia:  0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008
  // Mainnet:  0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45
  const ROUTER = process.env.ROUTER_ADDRESS ?? "0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008";

  // Owner and initial mint recipient both default to deployer.
  // Override via env vars if you want to separate them.
  const OWNER     = process.env.OWNER_ADDRESS     ?? deployer.address;
  const RECIPIENT = process.env.RECIPIENT_ADDRESS ?? deployer.address;

  const Erebus = await ethers.getContractFactory("Erebus");
  const erebus = await Erebus.deploy(ROUTER, OWNER, RECIPIENT);
  await erebus.waitForDeployment();

  const address = await erebus.getAddress();
  console.log("Erebus deployed to:", address);
  console.log("\nNext steps:");
  console.log("  1. Create V3 pool and note the pool address");
  console.log("  2. Call setupEREBUSPair(<poolAddress>)");
  console.log("  3. Call initialEREBUSMint(<recipientAddress>)");
  console.log("  4. Add one-sided LP at 0.025 ETH opening price");
  console.log("  5. Call startEREBUS() to open public trading");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
