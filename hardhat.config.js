const fs = require('fs');
require('@nomiclabs/hardhat-waffle');

module.exports = {
  networks: {
    hardhat: {
      chainId: 31337,
      throwOnTransactionFailures: true,
      throwOnCallFailures: true,
      allowUnlimitedContractSize: true,
      blockGasLimit: 0x1fffffffffffff,
    },
  },
  solidity: {
    version: '0.8.4',
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
};
