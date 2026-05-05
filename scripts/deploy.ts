import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();

  const router = "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45"; // SwapRouter02 mainnet

  console.log("Deployer:", deployer.address);
  const Erebus = await ethers.getContractFactory("Erebus");
  const erebus = await Erebus.deploy(router, deployer.address, deployer.address);
  await erebus.waitForDeployment();

  console.log("Erebus deployed:", await erebus.getAddress());
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});