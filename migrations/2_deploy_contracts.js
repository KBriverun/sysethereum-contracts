// Load zos scripts and truffle wrapper function
const { ConfigManager, scripts } = require('@openzeppelin/cli');
const { add, push, create } = scripts;

/* Retrieve compiled contract artifacts. */
const SyscoinERC20Asset = artifacts.require('./token/SyscoinERC20Asset.sol');


const SYSCOIN_MAINNET = 0;
const SYSCOIN_TESTNET = 1;
const SYSCOIN_REGTEST = 2;

const SUPERBLOCK_OPTIONS_PRODUCTION = {
  DURATION: 60,   // 60 blocks per superblock
  DELAY: 3 * 3600,  // 3 hours
  TIMEOUT: 600,     // 10 minutes
  CONFIRMATIONS: 3 // Superblocks required to confirm semi approved superblock
};

const SUPERBLOCK_OPTIONS_INTEGRATION_FAST_SYNC = {
  DURATION: 10,    // 10 blocks per superblock
  DELAY: 300,       // 5 minutes
  TIMEOUT: 300,      // 5 minutes
  CONFIRMATIONS: 3 // Superblocks required to confirm semi approved superblock
};

const SUPERBLOCK_OPTIONS_LOCAL = {
  DURATION: 60,     // 10 blocks per superblock
  DELAY: 60,        // 1 minute
  TIMEOUT: 30,      // 30 seconds
  CONFIRMATIONS: 1 // Superblocks required to confirm semi approved superblock
};

async function deploy(options, accounts, networkId, superblockOptions) {
  // Register contracts in the zos project
  add({ contractsData: [{ name: 'SyscoinSuperblocks', alias: 'SyscoinSuperblocks' }] });
  add({ contractsData: [{ name: 'SyscoinERC20Manager', alias: 'SyscoinERC20Manager' }] });
  add({ contractsData: [{ name: 'SyscoinBattleManager', alias: 'SyscoinBattleManager' }] });
  add({ contractsData: [{ name: 'SyscoinClaimManager', alias: 'SyscoinClaimManager' }] });

  // Push implementation contracts to the network
  console.log('Depolying implementations...');
  await push(options);

  // Create an instance of MyContract, setting initial value to 42
  console.log('\nDeploying SyscoinSuperblocks proxy instance at address ');
  let SyscoinSuperblocks = await create(Object.assign({ contractAlias: 'SyscoinSuperblocks' }, options));

  console.log('\nDeploying and Initializing SyscoinERC20Manager proxy instance at address ');
  let SyscoinERC20Manager = await create(Object.assign({ contractAlias: 'SyscoinERC20Manager', methodName: 'init', methodArgs: [SyscoinSuperblocks.address] }, options));

  console.log('\nDeploying and Initializing SyscoinBattleManager proxy instance at address ');
  let SyscoinBattleManager = await create(Object.assign({ contractAlias: 'SyscoinBattleManager', methodName: 'init', methodArgs: [networkId, SyscoinSuperblocks.address, superblockOptions.DURATION, superblockOptions.TIMEOUT] }, options));

  console.log('\nDeploying and Initializing SyscoinClaimManager proxy instance at address ');
  let SyscoinClaimManager = await create(Object.assign({ contractAlias: 'SyscoinClaimManager', methodName: 'init', methodArgs: [SyscoinSuperblocks.address, SyscoinBattleManager.address, superblockOptions.DELAY, superblockOptions.TIMEOUT, superblockOptions.CONFIRMATIONS] }, options));

  console.log('\nInitializing SyscoinSuperblocks...');
  let tx = await SyscoinSuperblocks.methods.init(SyscoinERC20Manager.address, SyscoinClaimManager.address).send({ from: accounts[0], gas: 300000 });
  console.log('TX hash: ', tx.transactionHash, '\n');

  console.log('Initializing SyscoinBattleManager...');
  tx = await SyscoinBattleManager.methods.setSyscoinClaimManager(SyscoinClaimManager.address).send({ from: accounts[0], gas: 300000 });
  console.log('TX hash: ', tx.transactionHash, '\n');
  return SyscoinERC20Manager.address;
}

module.exports = function(deployer, networkName, accounts) {
  console.log('Deploy wallet', accounts);
  deployer.then(async () => {
    let SyscoinERC20ManagerAddress;
    const { network, txParams } = await ConfigManager.initNetworkConfiguration({ network: networkName, from: accounts[0] })

    if (networkName === 'development') {
      SyscoinERC20ManagerAddress = await deploy({ network, txParams }, accounts, SYSCOIN_MAINNET, SUPERBLOCK_OPTIONS_LOCAL);
    } else {
      if (networkName === 'ropsten') {
        SyscoinERC20ManagerAddress = await deploy({ network, txParams }, accounts, SYSCOIN_MAINNET, SUPERBLOCK_OPTIONS_INTEGRATION_FAST_SYNC);
      } else if (networkName === 'rinkeby') {
        SyscoinERC20ManagerAddress = await deploy({ network, txParams }, accounts, SYSCOIN_TESTNET, SUPERBLOCK_OPTIONS_PRODUCTION);
      } else if (networkName === 'mainnet') {
        SyscoinERC20ManagerAddress = await deploy({ network, txParams }, accounts, SYSCOIN_MAINNET, SUPERBLOCK_OPTIONS_PRODUCTION);
      } else if (networkName === 'integrationSyscoinRegtest') {
        SyscoinERC20ManagerAddress = await deploy({ network, txParams }, accounts, SYSCOIN_REGTEST, SUPERBLOCK_OPTIONS_LOCAL);
      }
      await deployer.deploy(SyscoinERC20Asset,
        "SyscoinToken", "SYSX", 8, SyscoinERC20ManagerAddress,
        {gas: 2000000 }
      );
    }
  });
};
