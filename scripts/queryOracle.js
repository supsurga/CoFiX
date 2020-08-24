const NEST3PriceOracleMock = artifacts.require("NEST3PriceOracleMock");
const ERC20 = artifacts.require("ERC20");
const { BN } = require('@openzeppelin/test-helpers');
const { web3 } = require('@openzeppelin/test-environment');
const CofiXController = artifacts.require("CofiXController");

const argv = require('yargs').argv;

module.exports = async function (callback) {
    try {
        var PriceOracle;
        var Token;

        console.log(`argv> oracle=${argv.oracle}, token=${argv.token}, account=${argv.account}`);

        if (argv.oracle === "" || argv.oracle === undefined) {
            PriceOracle = await NEST3PriceOracleMock.deployed();
        } else {
            PriceOracle = await NEST3PriceOracleMock.at(argv.oracle);
        }
        if (argv.token === "" || argv.token === undefined) {
            Token = await ERC20.deployed();
        } else {
            Token = await ERC20.at(argv.token);
        }

        const CofiXCtrl = await CofiXController.deployed();

        // getPriceLength
        let priceLen = await PriceOracle.getPriceLength(Token.address);
        console.log(`getPriceLength=${priceLen.toString()}`);

        let symbol = await Token.symbol();
        console.log(`token symbol=${symbol}, address=${Token.address}, getPriceLength=${priceLen.toString()}`);

        // get price now from NEST3PriceOracleMock Contract
        let p = await PriceOracle.checkPriceNow(Token.address);
        let decimal = await Token.decimals();
        console.log(`price now> ethAmount=${p.ethAmount.toString()}, erc20Amount=${p.erc20Amount.toString()}, price=${p.erc20Amount.mul(new BN(web3.utils.toWei('1', 'ether'))).div(p.ethAmount).div((new BN('10')).pow(decimal)).toString()} ${symbol}/ETH`);

        // get K_BASE from CofiXController contract
        let k_base = await CofiXCtrl.K_BASE(); // 100000

        // queryOracle
        const _msgValue = web3.utils.toWei('0.01', 'ether');
        let result = await CofiXCtrl.queryOracle(Token.address, argv.account, { value: _msgValue });
        console.log("receipt.gasUsed:", result.receipt.gasUsed); // 494562
        let evtArgs0 = result.receipt.logs[0].args;
        console.log("evtArgs0> K:", evtArgs0.K.toString(), ", sigma:", evtArgs0.sigma.toString(), ", T:", evtArgs0.T.toString(), ", ethAmount:", evtArgs0.ethAmount.toString(), ", erc20Amount:", evtArgs0.erc20Amount.toString())

        // getKInfo
        let kInfo = await CofiXCtrl.getKInfo(Token.address);
        console.log(`kInfo> raw k: ${kInfo.k.toString()}, k meaning: ${kInfo.k.toString() / k_base.toString()}, updatedAt: ${kInfo.updatedAt.toString()}, update date: ${(new Date(kInfo.updatedAt*1000)).toUTCString()}`);
        callback();
    } catch (e) {
        callback(e);
    }
}