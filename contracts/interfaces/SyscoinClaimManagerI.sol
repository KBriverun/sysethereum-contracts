pragma solidity ^0.5.12;

import './SyscoinSuperblocksI.sol';

interface SyscoinClaimManagerI {
    function bondDeposit(bytes32 superblockHash, address account, uint amount) external returns (uint);

    function getDeposit(address account) external view returns (uint);

    function sessionDecided(bytes32 sessionId, bytes32 superblockHash, address winner, address loser) external;
}
