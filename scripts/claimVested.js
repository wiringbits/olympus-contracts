const { formatUnits } = require("ethers/lib/utils");
const { ethers } = require("hardhat");
const vesting_abi = require("../abis/token_vesting");
const provider = require("./provider");
require("dotenv").config();
const { PRIVATE_KEY } = process.env;
const BN = ethers.BigNumber;
async function main() {
    const [owner] = await ethers.getSigners();
    console.log(`Owner Account: ${owner.address}`);
    try {
        const vestingContractAddr = "";
        const account = "";
        const wallet = new ethers.Wallet(PRIVATE_KEY, provider.arbitrum);
        var contract = new ethers.Contract(vestingContractAddr, vesting_abi, wallet);
        const vestingScheduleId = await contract.computeVestingScheduleIdForAddressAndIndex(
            account,
            0
        );
        console.log("Vesting id:", vestingScheduleId);
        const amount = await contract.computeReleasableAmount(vestingScheduleId);
        console.log("Releasable amount:", formatUnits(amount.toString(), BN.from(18)));
        const release = await contract.release(vestingScheduleId, amount.toString());
        console.log(release);
    } catch (e) {
        console.log(e);
    }
}
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
