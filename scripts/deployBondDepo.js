const { ethers } = require("hardhat");

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying contracts with the account: " + deployer.address);

    const authority = "";
    const hdx = "";
    const gHdx = "";
    const staking = "";
    const treasury = "";

    const depoFactory = await ethers.getContractFactory("OlympusBondDepositoryV2");

    const depo = await depoFactory.deploy(authority, hdx, gHdx, staking, treasury);

    console.log("Bond Depo: " + depo.address);
}

main()
    .then(() => process.exit())
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
