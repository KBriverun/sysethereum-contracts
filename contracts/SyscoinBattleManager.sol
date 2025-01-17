pragma solidity ^0.5.10;

import './interfaces/SyscoinClaimManagerI.sol';
import './interfaces/SyscoinSuperblocksI.sol';
import './SyscoinErrorCodes.sol';
import './SyscoinParser/SyscoinMessageLibrary.sol';
import "@openzeppelin/upgrades/contracts/Initializable.sol";

// @dev - Manages a battle session between superblock submitter and challenger
contract SyscoinBattleManager is Initializable, SyscoinErrorCodes {

    enum ChallengeState {
        Unchallenged,             // Unchallenged submission
        Challenged,               // Claims was challenged
        QueryMerkleRootHashes,    // Challenger expecting block hashes
        RespondMerkleRootHashes,  // Block hashes were received and verified
        QueryLastBlockHeader,     // Challenger is requesting last block header
        PendingVerification,      // All block hashes were received and verified by merkle commitment to superblock merkle root set to pending superblock verification
        SuperblockVerified,       // Superblock verified
        SuperblockFailed          // Superblock not valid
    }

    enum BlockInfoStatus {
        Uninitialized,
        Requested,
		Verified
    }

    struct BlockInfo {
        bytes32 prevBlock;
        uint64 timestamp;
        uint32 bits;
        BlockInfoStatus status;
        bytes32 blockHash;
    }

    struct BattleSession {
        bytes32 id;
        bytes32 superblockHash;
        address submitter;
        address challenger;
        uint lastActionTimestamp;         // Last action timestamp
        uint lastActionClaimant;          // Number last action submitter
        uint lastActionChallenger;        // Number last action challenger
        uint actionsCounter;              // Counter session actions
        int blockIndexInvalidated;        // index of block in superblock where the block hash is different between challenger and submitter
        bytes32[] blockHashes;            // Block hashes

        BlockInfo blocksInfo;

        ChallengeState challengeState;    // Claim state
    }


    mapping (bytes32 => BattleSession) sessions;



    uint public superblockDuration;         // Superblock duration (in blocks)
    uint public superblockTimeout;          // Timeout action (in seconds)


    // network that the stored blocks belong to
    SyscoinMessageLibrary.Network private net;


    // Syscoin claim manager
    SyscoinClaimManagerI trustedSyscoinClaimManager;

    // Superblocks contract
    SyscoinSuperblocksI trustedSuperblocks;

    event NewBattle(bytes32 superblockHash, bytes32 sessionId, address submitter, address challenger);
    event ChallengerConvicted(bytes32 sessionId, address challenger);
    event SubmitterConvicted(bytes32 sessionId, address submitter);

    event QueryMerkleRootHashes(bytes32 sessionId, address submitter);
    event RespondMerkleRootHashes(bytes32 sessionId, address challenger);
    event QueryLastBlockHeader(bytes32 sessionId, address submitter);
    event RespondLastBlockHeader(bytes32 sessionId, address challenger);
    event ErrorBattle(bytes32 sessionId, uint err);
    modifier onlyFrom(address sender) {
        require(msg.sender == sender);
        _;
    }

    modifier onlyClaimant(bytes32 sessionId) {
        require(msg.sender == sessions[sessionId].submitter);
        _;
    }

    modifier onlyChallenger(bytes32 sessionId) {
        require(msg.sender == sessions[sessionId].challenger);
        _;
    }

    // @dev – Configures the contract managing superblocks battles
    // @param _network Network type to use for block difficulty validation
    // @param _superblocks Contract that manages superblocks
    // @param _superblockDuration Superblock duration (in blocks)
    // @param _superblockTimeout Time to wait for challenges (in seconds)
    function init(
        SyscoinMessageLibrary.Network _network,
        SyscoinSuperblocksI _superblocks,
        uint _superblockDuration,
        uint _superblockTimeout
    ) public initializer {
        net = _network;
        trustedSuperblocks = _superblocks;
        superblockDuration = _superblockDuration;
        superblockTimeout = _superblockTimeout;
    }

    function setSyscoinClaimManager(SyscoinClaimManagerI _syscoinClaimManager) public {
        require(address(trustedSyscoinClaimManager) == address(0) && address(_syscoinClaimManager) != address(0));
        trustedSyscoinClaimManager = _syscoinClaimManager;
    }

    // @dev - Start a battle session
    function beginBattleSession(bytes32 superblockHash, address submitter, address challenger)
        onlyFrom(address(trustedSyscoinClaimManager)) public returns (bytes32) {
        bytes32 sessionId = keccak256(abi.encode(superblockHash, msg.sender, challenger));
        BattleSession storage session = sessions[sessionId];
        if(session.id != 0x0){
            revert();
        }
        session.id = sessionId;
        session.superblockHash = superblockHash;
        session.submitter = submitter;
        session.challenger = challenger;
        session.lastActionTimestamp = block.timestamp;
        session.lastActionChallenger = 0;
        session.lastActionClaimant = 1;     // Force challenger to start
        session.actionsCounter = 1;
        session.challengeState = ChallengeState.Challenged;


        emit NewBattle(superblockHash, sessionId, submitter, challenger);
        return sessionId;
    }

    // @dev - Challenger makes a query for superblock hashes
    function doQueryMerkleRootHashes(BattleSession storage session) internal returns (uint) {
        if (session.challengeState == ChallengeState.Challenged) {
            session.challengeState = ChallengeState.QueryMerkleRootHashes;
            assert(msg.sender == session.challenger);
            return ERR_SUPERBLOCK_OK;
        }
        return ERR_SUPERBLOCK_BAD_STATUS;
    }

    // @dev - Challenger makes a query for superblock hashes
    function queryMerkleRootHashes(bytes32 sessionId) onlyChallenger(sessionId) public {
        BattleSession storage session = sessions[sessionId];
        uint err = doQueryMerkleRootHashes(session);
        if (err != ERR_SUPERBLOCK_OK) {
            emit ErrorBattle(sessionId, err);
        } else {
            session.actionsCounter += 1;
            session.lastActionTimestamp = block.timestamp;
            session.lastActionChallenger = session.actionsCounter;
            emit QueryMerkleRootHashes(sessionId, session.submitter);
        }
    }

    // @dev - Submitter sends hashes to verify superblock merkle root
    function doVerifyMerkleRootHashes(BattleSession storage session, bytes32[] memory blockHashes) internal returns (uint) {
        require(session.blockHashes.length == 0);
        if (session.challengeState == ChallengeState.QueryMerkleRootHashes) {
            (bytes32 merkleRoot, , ,bytes32 lastHash,, , ,,) = getSuperblockInfo(session.superblockHash);
            if (lastHash != blockHashes[blockHashes.length - 1]){
                return ERR_SUPERBLOCK_BAD_LASTBLOCK;
            }
            if(net != SyscoinMessageLibrary.Network.REGTEST && blockHashes.length != superblockDuration){
                return ERR_SUPERBLOCK_BAD_BLOCKHEIGHT;
            }
            if (merkleRoot != SyscoinMessageLibrary.makeMerkle(blockHashes)) {
                return ERR_SUPERBLOCK_INVALID_MERKLE;
            }

            session.blockHashes = blockHashes;
            session.challengeState = ChallengeState.RespondMerkleRootHashes;
            return ERR_SUPERBLOCK_OK;
        }
        return ERR_SUPERBLOCK_BAD_STATUS;
    }

    // @dev - For the submitter to respond to challenger queries
    function respondMerkleRootHashes(bytes32 sessionId, bytes32[] memory blockHashes) onlyClaimant(sessionId) public {
        BattleSession storage session = sessions[sessionId];
        uint err = doVerifyMerkleRootHashes(session, blockHashes);
        if (err != 0) {
            emit ErrorBattle(sessionId, err);
        } else {
            session.actionsCounter += 1;
            session.lastActionTimestamp = block.timestamp;
            session.lastActionClaimant = session.actionsCounter;
            emit RespondMerkleRootHashes(sessionId, session.challenger);
        }
    }
       
    // @dev - Challenger makes a query for last block header
    function doQueryLastBlockHeader(BattleSession storage session, int blockIndexInvalidated) internal returns (uint) {
        if (session.challengeState == ChallengeState.RespondMerkleRootHashes) {
            require(session.blocksInfo.status == BlockInfoStatus.Uninitialized);
            session.challengeState = ChallengeState.QueryLastBlockHeader;
            session.blocksInfo.status = BlockInfoStatus.Requested;
            if(blockIndexInvalidated < -1 || blockIndexInvalidated >= int(session.blockHashes.length)){
                return ERR_SUPERBLOCK_BAD_INTERIM_BLOCKINDEX;
            }
            session.blockIndexInvalidated = blockIndexInvalidated;
            return ERR_SUPERBLOCK_OK;
        }
        return ERR_SUPERBLOCK_BAD_STATUS;
    }

    // @dev - For the challenger to start a query
    function queryLastBlockHeader(bytes32 sessionId, int blockIndexInvalidated) onlyChallenger(sessionId) public {
        BattleSession storage session = sessions[sessionId];
        uint err = doQueryLastBlockHeader(session, blockIndexInvalidated);
        if (err != ERR_SUPERBLOCK_OK) {
            emit ErrorBattle(sessionId, err);
        } else {
            session.actionsCounter += 1;
            session.lastActionTimestamp = block.timestamp;
            session.lastActionChallenger = session.actionsCounter;
            emit QueryLastBlockHeader(sessionId, session.submitter);
        }
    }

    // @dev - Verify Syscoin block AuxPoW
    function verifyBlockAuxPoW(
        BlockInfo storage blockInfo,
        bytes32 blockHash,
        bytes memory blockHeader
    ) internal returns (uint) {
        uint err = SyscoinMessageLibrary.verifyBlockHeader(blockHeader, 0, uint(blockHash));
        if (err != 0) {
            return err;
        }
        blockInfo.timestamp = SyscoinMessageLibrary.getTimestamp(blockHeader);
        blockInfo.bits = SyscoinMessageLibrary.getBits(blockHeader);
        blockInfo.prevBlock = bytes32(SyscoinMessageLibrary.getHashPrevBlock(blockHeader));
        blockInfo.blockHash = blockHash;
        return ERR_SUPERBLOCK_OK;
    }

    // @dev - Verify block header sent by challenger
    function doRespondLastBlockHeader(
        BattleSession storage session,
        bytes memory blockLastHeader,
        bytes memory blockInterimHeader
    ) internal returns (uint) {
        if (session.challengeState == ChallengeState.QueryLastBlockHeader) {
            uint lastIndex = session.blockHashes.length-1;
            BlockInfo storage blockInfo = session.blocksInfo;
            if (blockInfo.status != BlockInfoStatus.Requested) {
                return (ERR_SUPERBLOCK_BAD_SYSCOIN_STATUS);
            }

			// pass in blockSha256Hash here instead of proposedScryptHash because we
            // don't need a proposed hash (we already calculated it here, syscoin uses 
            // sha256 just like bitcoin)
            uint err = verifyBlockAuxPoW(blockInfo, session.blockHashes[lastIndex], blockLastHeader);
            if (err != ERR_SUPERBLOCK_OK) {
                return (err);
            }
            bool emptyHeader = blockInterimHeader.length == 0;
            bool noIndex = session.blockIndexInvalidated == -1;

            if (!noIndex && emptyHeader) return ERR_SUPERBLOCK_INTERIMBLOCK_MISSING;
            if (noIndex && !emptyHeader) return ERR_SUPERBLOCK_BAD_INTERIM_BLOCKINDEX;
  
            // if interim header is passed in (last block is identical but another block is not matching, then validate the interim block and that it links to the chain of hashes stored in the session from merkle root hash response coming from defender)
            if(blockInterimHeader.length > 0){
                uint blockIndex = uint(session.blockIndexInvalidated);    
                bytes32 blockSha256HashInterim = session.blockHashes[blockIndex];
                err = SyscoinMessageLibrary.verifyBlockHeader(blockInterimHeader, 0, uint(blockSha256HashInterim));
                if (err != 0) {
                    return err;
                }
                bytes32 blockInterimHeaderPrevBlockHash = bytes32(SyscoinMessageLibrary.getHashPrevBlock(blockInterimHeader));
                bytes32 superBlockPrevBlockHash;
                // if index is 0 then check last block of prev superblock
                if(blockIndex == 0){
                    bytes32 parentId = trustedSuperblocks.getSuperblockParentId(session.superblockHash);
                    superBlockPrevBlockHash = trustedSuperblocks.getSuperblockLastHash(parentId);
                }
                // else we look at the prev block hash in the session
                else{
                    superBlockPrevBlockHash = session.blockHashes[blockIndex-1];
                }
                // check to ensure the block hash of the invalidated index - 1 (prev block) or prev superblock if index == 0 matches that of the prevblock of the block header of the offending mismatched block
                if(blockInterimHeaderPrevBlockHash != superBlockPrevBlockHash){
                    return (ERR_SUPERBLOCK_BAD_INTERIM_PREVHASH);
                }
            }
            session.challengeState = ChallengeState.PendingVerification;
            blockInfo.status = BlockInfoStatus.Verified;
            return (ERR_SUPERBLOCK_OK);
        }
        return (ERR_SUPERBLOCK_BAD_STATUS);
    }
    function respondLastBlockHeader(
        bytes32 sessionId,
        bytes memory blockLastHeader,
        bytes memory blockInterimHeader
        ) onlyClaimant(sessionId) public {
        BattleSession storage session = sessions[sessionId];
        (uint err) = doRespondLastBlockHeader(session, blockLastHeader, blockInterimHeader);
        if (err != 0) {
            emit ErrorBattle(sessionId, err);
        }else{
            session.actionsCounter += 1;
            session.lastActionTimestamp = block.timestamp;
            session.lastActionClaimant = session.actionsCounter;
            emit RespondLastBlockHeader(sessionId, session.challenger);
        }
    }     

    // @dev - Validate superblock information from last blocks
    function validateLastBlocks(BattleSession storage session) internal view returns (uint) {
        if (session.blockHashes.length <= 0) {
            return ERR_SUPERBLOCK_BAD_LASTBLOCK;
        }
        uint lastTimestamp;
        uint prevTimestamp;
        bytes32 parentId;
        bytes32 lastBlockHash;
        (, , lastTimestamp, lastBlockHash, ,parentId,,,) = getSuperblockInfo(session.superblockHash);
        bytes32 blockSha256Hash = session.blockHashes[session.blockHashes.length - 1];
        BlockInfo storage blockInfo = session.blocksInfo;
        if(net != SyscoinMessageLibrary.Network.REGTEST){
            bytes32 prevBlockSha256Hash = session.blockHashes[session.blockHashes.length - 2];
            if(blockInfo.prevBlock != prevBlockSha256Hash){
                return ERR_SUPERBLOCK_BAD_PREVBLOCK;
            }
        }

        
        if(blockSha256Hash != lastBlockHash){
            return ERR_SUPERBLOCK_BAD_LASTBLOCK;
        }
        if (blockInfo.timestamp != lastTimestamp) {
            return ERR_SUPERBLOCK_BAD_TIMESTAMP;
        }
        if (blockInfo.status != BlockInfoStatus.Verified) {
            return ERR_SUPERBLOCK_BAD_LASTBLOCK_STATUS;
        }
        (, ,prevTimestamp , ,,,, , ) = getSuperblockInfo(parentId);
        
        if (prevTimestamp > lastTimestamp) {
            return ERR_SUPERBLOCK_BAD_TIMESTAMP;
        }
        return ERR_SUPERBLOCK_OK;
    }

    // @dev - Validate superblock accumulated work
    function validateProofOfWork(BattleSession storage session) internal view returns (uint) {
        uint accWork;
        bytes32 prevBlock;
        uint prevWork;
        uint32 prevBits;
        uint superblockHeight;
        bytes32 superblockHash = session.superblockHash;
        (, accWork, ,,prevBits,prevBlock,,,superblockHeight) = getSuperblockInfo(superblockHash);
        BlockInfo storage blockInfo = session.blocksInfo;
        if(accWork <= 0){
            return ERR_SUPERBLOCK_BAD_ACCUMULATED_WORK;
        }    
        if(prevBits != blockInfo.bits){
            return ERR_SUPERBLOCK_BAD_MISMATCH;
        }
        (, prevWork, ,, prevBits,, ,,) = getSuperblockInfo(prevBlock);
        if(accWork <= prevWork){
            return ERR_SUPERBLOCK_INVALID_ACCUMULATED_WORK;
        }
        // make sure every 7th superblock adjusts difficulty
        if(net == SyscoinMessageLibrary.Network.MAINNET){
            if(((superblockHeight-2) % 6) == 0){
                // make sure difficulty adjustment is within bounds
                uint32 lowerBoundDiff = SyscoinMessageLibrary.calculateDifficulty(SyscoinMessageLibrary.getLowerBoundDifficultyTarget()-1, prevBits);
                uint32 upperBoundDiff = SyscoinMessageLibrary.calculateDifficulty(SyscoinMessageLibrary.getUpperBoundDifficultyTarget()+1, prevBits);
                if(blockInfo.bits < lowerBoundDiff || blockInfo.bits > upperBoundDiff){
                    return ERR_SUPERBLOCK_BAD_RETARGET;
                }          
            }
            // within the 7th make sure bits don't change
            else if(prevBits != blockInfo.bits){
                return ERR_SUPERBLOCK_BAD_BITS;
            }

            uint newWork = prevWork + (SyscoinMessageLibrary.getWorkFromBits(blockInfo.bits)*superblockDuration);

            if (newWork != accWork) {
                return ERR_SUPERBLOCK_BAD_ACCUMULATED_WORK;
            }
        }   
        return ERR_SUPERBLOCK_OK;
    }
    // @dev - Verify whether a superblock's data is consistent
    // Only should be called when all blocks header were submitted
    function doVerifySuperblock(BattleSession storage session, bytes32 sessionId) internal returns (uint) {
        if (session.challengeState == ChallengeState.PendingVerification) {
            uint err;
            err = validateLastBlocks(session);
            if (err != 0) {
                emit ErrorBattle(sessionId, err);
                return 2;
            }
            err = validateProofOfWork(session);
            if (err != 0) {
                emit ErrorBattle(sessionId, err);
                return 2;
            }
            return 1;
        } else if (session.challengeState == ChallengeState.SuperblockFailed) {
            return 2;
        }
        return 0;
    }

    // @dev - Perform final verification once all blocks were submitted
    function verifySuperblock(bytes32 sessionId) public {
        BattleSession storage session = sessions[sessionId];
        uint status = doVerifySuperblock(session, sessionId);
        if (status == 1) {
            convictChallenger(sessionId);
        } else if (status == 2) {
            convictSubmitter(sessionId);
        }
    }

    // @dev - Trigger conviction if response is not received in time
    function timeout(bytes32 sessionId) public returns (uint) {
        BattleSession storage session = sessions[sessionId];
        if (session.challengeState == ChallengeState.SuperblockFailed ||
            (session.lastActionChallenger > session.lastActionClaimant &&
            block.timestamp > session.lastActionTimestamp + superblockTimeout)) {
            convictSubmitter(sessionId);
            return ERR_SUPERBLOCK_OK;
        } else if (session.lastActionClaimant > session.lastActionChallenger &&
            block.timestamp > session.lastActionTimestamp + superblockTimeout) {
            convictChallenger(sessionId);
            return ERR_SUPERBLOCK_OK;
        }
        emit ErrorBattle(sessionId, ERR_SUPERBLOCK_NO_TIMEOUT);
        return ERR_SUPERBLOCK_NO_TIMEOUT;
    }

    // @dev - To be called when a challenger is convicted
    function convictChallenger(bytes32 sessionId) internal {
        BattleSession storage session = sessions[sessionId];
        sessionDecided(sessionId, session.superblockHash, session.submitter, session.challenger);
        disable(sessionId);
        emit ChallengerConvicted(sessionId, session.challenger);
    }

    // @dev - To be called when a submitter is convicted
    function convictSubmitter(bytes32 sessionId) internal {
        BattleSession storage session = sessions[sessionId];
        sessionDecided(sessionId, session.superblockHash, session.challenger, session.submitter);
        disable(sessionId);
        emit SubmitterConvicted(sessionId, session.submitter);
    }

    // @dev - Disable session
    // It should be called only when either the submitter or the challenger were convicted.
    function disable(bytes32 sessionId) internal {
        delete sessions[sessionId];
    }

    // @dev - Check if a session's challenger did not respond before timeout
    function getChallengerHitTimeout(bytes32 sessionId) public view returns (bool) {
        BattleSession storage session = sessions[sessionId];
        return (session.lastActionClaimant > session.lastActionChallenger &&
            block.timestamp > session.lastActionTimestamp + superblockTimeout);
    }

    // @dev - Check if a session's submitter did not respond before timeout
    function getSubmitterHitTimeout(bytes32 sessionId) public view returns (bool) {
        BattleSession storage session = sessions[sessionId];
        return (session.lastActionChallenger > session.lastActionClaimant &&
            block.timestamp > session.lastActionTimestamp + superblockTimeout);
    }

    function getSuperblockBySession(bytes32 sessionId) public view returns (bytes32) {
        return sessions[sessionId].superblockHash;
    }
    function getBlockHashesBySession(bytes32 sessionId) public view returns (bytes32[] memory blockHashes) {
        return sessions[sessionId].blockHashes;
    }
    function getInvalidatedBlockIndexBySession(bytes32 sessionId) public view returns (int) {
        return sessions[sessionId].blockIndexInvalidated;
    }
    function getSessionStatus(bytes32 sessionId) public view returns (BlockInfoStatus) {
        BattleSession storage session = sessions[sessionId];
        return session.blocksInfo.status;
    }
    function getSessionChallengeState(bytes32 sessionId) public view returns (ChallengeState) {
        return sessions[sessionId].challengeState;
    }
    // @dev - To be called when a battle sessions  was decided
    function sessionDecided(bytes32 sessionId, bytes32 superblockHash, address winner, address loser) internal {
        trustedSyscoinClaimManager.sessionDecided(sessionId, superblockHash, winner, loser);
    }

    // @dev - Retrieve superblock information
    function getSuperblockInfo(bytes32 superblockHash) internal view returns (
        bytes32 _blocksMerkleRoot,
        uint _accumulatedWork,
        uint _timestamp,
        bytes32 _lastHash,
        uint32 _lastBits,
        bytes32 _parentId,
        address _submitter,
        SyscoinSuperblocksI.Status _status,
        uint32 _height
    ) {
        return trustedSuperblocks.getSuperblock(superblockHash);
    }
    
    // @dev - Verify whether a user has a certain amount of deposits or more
    function hasDeposit(address who, uint amount) internal view returns (bool) {
        return trustedSyscoinClaimManager.getDeposit(who) >= amount;
    }

    // @dev – locks up part of a user's deposit into a claim.
    function bondDeposit(bytes32 superblockHash, address account, uint amount) internal returns (uint) {
        return trustedSyscoinClaimManager.bondDeposit(superblockHash, account, amount);
    }
}
