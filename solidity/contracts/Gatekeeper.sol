pragma solidity ^0.5.10;

/* node modules */
import "@0x/contracts-utils/contracts/src/LibBytes.sol";
import "gsn-sponsor/contracts/GsnRecipient.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "tabookey-gasless/contracts/GsnUtils.sol";

import "./PermissionsLevel.sol";
import "./Utilities.sol";
import "./BypassPolicy.sol";


contract Gatekeeper is PermissionsLevel, GsnRecipient {

    using LibBytes for bytes;

    // Nice idea to use mock token address for ETH instead of 'address(0)'
    address constant internal ETH_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    enum ChangeType {
        ADD_PARTICIPANT, // arg: participant_hash
        REMOVE_PARTICIPANT, // arg: participant_hash
        ADD_BYPASS_BY_TARGET,
        ADD_BYPASS_BY_METHOD,
        UNFREEZE            // no args
    }

    //***** events

    event ConfigPending(bytes32 indexed transactionHash, address sender, uint32 senderPermsLevel, address booster, uint32 boosterPermsLevel, uint256 stateId, uint8[] actions, bytes32[] actionsArguments1, bytes32[] actionsArguments2);
    event ConfigCancelled(bytes32 indexed transactionHash, address sender);
    // TODO: add 'ConfigApplied' event - this is the simplest way to track what is applied and whatnot
    event ParticipantAdded(bytes32 indexed participant);
    event ParticipantRemoved(bytes32 indexed participant);
    event OwnerChanged(address indexed newOwner);
    // TODO: not log participants
    event GatekeeperInitialized(bytes32[] participants, uint256[] delays, address trustedForwarder, address relayHub);
    event LevelFrozen(uint256 frozenLevel, uint256 frozenUntil, address sender);
    event UnfreezeCompleted();
    event BypassByTargetAdded(address target, BypassPolicy bypass);
    event BypassByMethodAdded(bytes4 method, BypassPolicy bypass);
    event BypassByTargetRemoved(address target, BypassPolicy bypass);
    event BypassByMethodRemoved(bytes4 method, BypassPolicy bypass);
    event BypassCallPending(bytes32 indexed bypassHash, uint256 stateNonce, address sender, uint32 senderPermsLevel, address target, uint256 value, bytes msgdata);
    event BypassCallCancelled(bytes32 indexed bypassHash, address sender);
    event BypassCallApplied(bytes32 indexed bypassHash, bool status);
    event BypassCallExecuted(bool status);

    DefaultBypassPolicy defaultBypassPolicy = new DefaultBypassPolicy();

    struct PendingChange {
        uint256 dueTime;
        address caller;
        uint256 requiredApprovals;
        uint256 approvals;
        mapping (bytes32 => bool) approvers;
    }

    mapping(bytes32 => PendingChange) public pendingChanges;
    uint256[] public delays;
    mapping(address => BypassPolicy) bypassPoliciesByTarget; // instance level bypass exceptions
    mapping(bytes4 => BypassPolicy) bypassPoliciesByMethod; // interface (method sigs) level bypass exceptions
    // TODO: do not call this 'bypass calls', this does not describe what these are.
    mapping(bytes32 => PendingChange) public pendingBypassCalls;
    bool public blockAcceleratedCalls;

    function getDelays() public view returns (uint256[] memory) {
        return delays;
    }

    mapping(bytes32 => bool) public participants;

    uint256 public frozenLevel;
    uint256 public frozenUntil;

    uint256 public stateNonce;

    uint256 public deployedBlock;

    constructor() public {
        deployedBlock = block.number;
    }


    // ********** Access control modifiers below this point

    function requireNotFrozen(uint32 senderPermsLevel, string memory errorMessage) view internal {
        uint8 senderLevel = extractLevel(senderPermsLevel);
        require(now > frozenUntil || senderLevel > frozenLevel, errorMessage);
    }

    function requireNotFrozen(uint32 senderPermsLevel) view internal {
        requireNotFrozen(senderPermsLevel, "level is frozen");
    }

    function isParticipant(address participant, uint32 permsLevel) view internal returns (bool) {
        return participants[Utilities.participantHash(participant, permsLevel)];
    }

    function requireParticipant(address participant, uint32 permsLevel) view internal {
        require(isParticipant(participant, permsLevel), "not participant");
    }

    function requirePermissions(address sender, uint32 neededPermissions, uint32 senderPermsLevel) view internal {
        requireParticipant(sender, senderPermsLevel);
        uint32 senderPermissions = extractPermission(senderPermsLevel);
        comparePermissions(neededPermissions, senderPermissions);
    }

    function requireCorrectState(uint256 targetStateNonce) view internal {
        require(stateNonce == targetStateNonce, "contract state changed since transaction was created");
    }

    uint256 constant maxParticipants = 20;
    uint256 constant maxLevels = 10;
    uint256 constant maxDelay = 365 days;
    uint256 constant maxFreeze = 365 days;


    function initialConfig(
        bytes32[] memory initialParticipants,
        uint256[] memory initialDelays,
        address _trustedForwarder,
        address _relayHub,
        bool _blockAcceleratedCalls) public {
        require(stateNonce == 0, "already initialized");
        require(initialParticipants.length <= maxParticipants, "too many participants");
        require(initialDelays.length <= maxLevels, "too many levels");

        setGsnForwarder(_trustedForwarder, _relayHub);
        for (uint8 i = 0; i < initialParticipants.length; i++) {
            participants[initialParticipants[i]] = true;
        }
        for (uint8 i = 0; i < initialDelays.length; i++) {
            require(initialDelays[i] < maxDelay, "Delay too long");
        }
        delays = initialDelays;
        blockAcceleratedCalls = _blockAcceleratedCalls;

        emit GatekeeperInitialized(initialParticipants, delays, _trustedForwarder, _relayHub);
        stateNonce++;
    }

    // ****** Immediately runnable functions below this point

    function freeze(uint32 senderPermsLevel, uint8 levelToFreeze, uint256 duration)
    public
    {
        address sender = getSender();
        requirePermissions(sender, canFreeze, senderPermsLevel);
        requireNotFrozen(senderPermsLevel);
        uint256 until = SafeMath.add(now, duration);
        uint8 senderLevel = extractLevel(senderPermsLevel);
        require(levelToFreeze <= senderLevel, "cannot freeze level that is higher than caller");
        require(levelToFreeze >= frozenLevel, "cannot freeze level that is lower than already frozen");
        require(duration <= maxFreeze, "cannot freeze level for this long");
        require(frozenUntil <= until, "cannot freeze level for less than already frozen");
        require(duration > 0, "cannot freeze level for zero time");

        frozenLevel = levelToFreeze;
        frozenUntil = until;
        emit LevelFrozen(frozenLevel, frozenUntil, sender);
        stateNonce++;
    }

    function addOperatorNow(uint32 senderPermsLevel, address newOperator) public {
        address sender = getSender();
        requirePermissions(sender, canAddOperator, senderPermsLevel);
        requireNotFrozen(senderPermsLevel);
        require(!blockAcceleratedCalls, "Accelerated calls blocked");
        uint8[] memory actions = new uint8[](1);
        bytes32[] memory args = new bytes32[](1);
        actions[0] = uint8(ChangeType.ADD_PARTICIPANT);
        args[0] = Utilities.participantHash(newOperator, ownerPermissions);
        bytes32 hash = Utilities.transactionHash(actions, args, args, stateNonce, sender, senderPermsLevel, address(0), 0);
        pendingChanges[hash] = PendingChange(SafeMath.add(now, delays[extractLevel(senderPermsLevel)]), getSender(), 1, 0);
//        addParticipant(sender, senderPermsLevel, Utilities.participantHash(newOperator, ownerPermissions));

        stateNonce++;

    }

    function removeBypassByTarget(uint32 senderPermsLevel, address target) public {
        address sender = getSender();
        requirePermissions(sender, canChangeBypass, senderPermsLevel);
        requireNotFrozen(senderPermsLevel);
        BypassPolicy bypass = bypassPoliciesByTarget[target];
        delete bypassPoliciesByTarget[target];
        emit BypassByTargetRemoved(target, bypass);
    }

    function removeBypassByMethod(uint32 senderPermsLevel, bytes4 method) public {
        address sender = getSender();
        requirePermissions(sender, canChangeBypass, senderPermsLevel);
        requireNotFrozen(senderPermsLevel);
        BypassPolicy bypass = bypassPoliciesByMethod[method];
        delete bypassPoliciesByMethod[method];
        emit BypassByMethodRemoved(method, bypass);
    }

    function boostedConfigChange(
        uint32 boosterPermsLevel,
        uint8[] memory actions,
        bytes32[] memory args1,
        bytes32[] memory args2,
        uint256 targetStateNonce,
        uint32 signerPermsLevel,
        bytes memory signature)
    public {
        address sender = getSender();
        requirePermissions(sender, canExecuteBoosts, boosterPermsLevel);
        requireNotFrozen(boosterPermsLevel);
        requireCorrectState(targetStateNonce);
        address signer = Utilities.recoverConfigSigner(actions, args1, args2, stateNonce, signature);
        requirePermissions(signer, canSignBoosts | canChangeConfig, signerPermsLevel);
        changeConfigurationInternal(actions, args1, args2, signer, signerPermsLevel, sender, boosterPermsLevel);
    }


    function changeConfiguration(
        uint32 senderPermsLevel,
        uint8[] memory actions,
        bytes32[] memory args1,
        bytes32[] memory args2,
        uint256 targetStateNonce)
    public
    {
        address realSender = getSender();
        requirePermissions(realSender, canChangeConfig, senderPermsLevel);
        requireNotFrozen(senderPermsLevel);
        requireCorrectState(targetStateNonce);
        changeConfigurationInternal(actions, args1, args2, realSender, senderPermsLevel, address(0), 0);
    }

    // Note: this internal method is not wrapped with 'requirePermissions' as it may be called by the 'changeOwner'
    function changeConfigurationInternal(
        uint8[] memory actions,
        bytes32[] memory args1,
        bytes32[] memory args2,
        address sender,
        uint32 senderPermsLevel,
        address booster,
        uint32 boosterPermsLevel
    ) internal {
        bytes32 transactionHash = Utilities.transactionHash(actions, args1, args2, stateNonce, sender, senderPermsLevel, booster, boosterPermsLevel);
        pendingChanges[transactionHash] = PendingChange(SafeMath.add(now, delays[extractLevel(senderPermsLevel)]), sender, 0, 0);
        emit ConfigPending(transactionHash, sender, senderPermsLevel, booster, boosterPermsLevel, stateNonce, actions, args1, args2);
        stateNonce++;
    }

    function cancelOperation(
        uint8[] memory actions,
        bytes32[] memory args1,
        bytes32[] memory args2,
        uint256 scheduledStateId,
        address scheduler,
        uint32 schedulerPermsLevel,
        address booster,
        uint32 boosterPermsLevel,
        uint32 senderPermsLevel)
    public {
        address sender = getSender();
        requirePermissions(sender, canCancel, senderPermsLevel);
        requireNotFrozen(senderPermsLevel);
        bytes32 hash = Utilities.transactionHash(actions, args1, args2, scheduledStateId, scheduler, schedulerPermsLevel, booster, boosterPermsLevel);
        require(pendingChanges[hash].dueTime > 0, "cannot cancel, operation does not exist");
        // TODO: refactor, make function or whatever
        if (booster != address(0)) {
            require(extractLevel(boosterPermsLevel) <= extractLevel(senderPermsLevel), "cannot cancel, booster is of higher level");
        }
        else {
            require(extractLevel(schedulerPermsLevel) <= extractLevel(senderPermsLevel), "cannot cancel, scheduler is of higher level");
        }
        delete pendingChanges[hash];
        emit ConfigCancelled(hash, sender);
        stateNonce++;
    }

    function approveConfig(
        uint32 senderPermsLevel,
        uint8[] memory actions,
        bytes32[] memory args1,
        bytes32[] memory args2,
        uint256 scheduledStateId,
        address scheduler,
        uint32 schedulerPermsLevel,
        address booster,
        uint32 boosterPermsLevel) public {
        address sender = getSender();
        requirePermissions(sender, canApprove, senderPermsLevel);
        requireNotFrozen(senderPermsLevel);
        if (booster != address(0))
        {
            requireNotFrozen(boosterPermsLevel, "booster level is frozen");
        }
        else {
            requireNotFrozen(schedulerPermsLevel, "scheduler level is frozen");
        }
        bytes32 transactionHash = Utilities.transactionHash(actions, args1, args2, scheduledStateId, scheduler, schedulerPermsLevel, booster, boosterPermsLevel);
        PendingChange storage pendingChange = pendingChanges[transactionHash];
        require(pendingChange.requiredApprovals > 0, "Operation doesn't support approvals");
        require(!pendingChange.approvers[Utilities.participantHash(sender, senderPermsLevel)], "Cannot approve twice");
        //TODO: separate the checks above to different function shared between applyConfig & approveConfig
        pendingChange.approvals++;
        if (pendingChange.approvals == pendingChange.requiredApprovals) {
            applyConfig(senderPermsLevel, actions, args1, args2, scheduledStateId, scheduler, schedulerPermsLevel, booster, boosterPermsLevel);
        }else {
            stateNonce++;
        }



    }

    function applyConfig(
        uint32 senderPermsLevel,
        uint8[] memory actions,
        bytes32[] memory args1,
        bytes32[] memory args2,
        uint256 scheduledStateId,
        address scheduler,
        uint32 schedulerPermsLevel,
        address booster,
        uint32 boosterPermsLevel)
    public {
        address sender = getSender();
        requireParticipant(sender, senderPermsLevel);
        requireNotFrozen(senderPermsLevel);
        if (booster != address(0))
        {
            requireNotFrozen(boosterPermsLevel, "booster level is frozen");
        }
        else {
            requireNotFrozen(schedulerPermsLevel, "scheduler level is frozen");
        }
        bytes32 transactionHash = Utilities.transactionHash(actions, args1, args2, scheduledStateId, scheduler, schedulerPermsLevel, booster, boosterPermsLevel);
        PendingChange memory pendingChange = pendingChanges[transactionHash];
        require(pendingChange.dueTime != 0, "apply called for non existent pending change");
        delete pendingChanges[transactionHash];
        // We can accelerate the config change with approvals - currently only  standalone (not batched operation) addOperator can be accelerated
        if (pendingChange.requiredApprovals > 0 && pendingChange.dueTime < now) {
            require(pendingChange.approvals >= pendingChange.requiredApprovals, "Pending approvals");
        }else {
            require(now >= pendingChange.dueTime, "apply called before due time");
        }
        for (uint256 i = 0; i < actions.length; i++) {
            dispatch(actions[i], args1[i], args2[i], scheduler, schedulerPermsLevel);
        }
        // TODO: do this in every method, as a function/modifier
        stateNonce++;
    }

    function dispatch(uint8 actionInt, bytes32 arg1, bytes32 arg2, address sender, uint32 senderPermsLevel) private {
        ChangeType action = ChangeType(actionInt);
        if (action == ChangeType.ADD_PARTICIPANT) {
            addParticipant(sender, senderPermsLevel, arg1);
        }
        else if (action == ChangeType.REMOVE_PARTICIPANT) {
            removeParticipant(sender, senderPermsLevel, arg1);
        }
        else if (action == ChangeType.UNFREEZE) {
            unfreeze(sender, senderPermsLevel);
        }
        else if (action == ChangeType.ADD_BYPASS_BY_TARGET) {
            addBypassByTarget(sender, senderPermsLevel, address(uint256(arg1)), BypassPolicy(uint256(arg2)));
        }
        else if (action == ChangeType.ADD_BYPASS_BY_METHOD) {
            addBypassByMethod(sender, senderPermsLevel, bytes4(arg1), BypassPolicy(uint256(arg2)));
        }
        else {
            revert("operation not supported");
        }
    }


    // ********** Delayed operations below this point

    function addParticipant(address sender, uint32 senderPermsLevel, bytes32 hash) private {
        requirePermissions(sender, canChangeParticipants, senderPermsLevel);
        participants[hash] = true;
        emit ParticipantAdded(hash);
    }

    function addBypassByTarget(address sender, uint32 senderPermsLevel, address target, BypassPolicy bypass) private {
        requirePermissions(sender, canChangeBypass, senderPermsLevel);
        bypassPoliciesByTarget[target] = bypass;
        emit BypassByTargetAdded(target, bypass);
    }

    function addBypassByMethod(address sender, uint32 senderPermsLevel, bytes4 method, BypassPolicy bypass) private {
        requirePermissions(sender, canChangeBypass, senderPermsLevel);
        bypassPoliciesByMethod[method] = bypass;
        emit BypassByMethodAdded(method, bypass);
    }

    function removeParticipant(address sender, uint32 senderPermsLevel, bytes32 participant) private {
        requirePermissions(sender, canChangeParticipants, senderPermsLevel);
        require(participants[participant], "there is no such participant");
        delete participants[participant];
        emit ParticipantRemoved(participant);
    }

    function unfreeze(address sender, uint32 senderPermsLevel) private {
        requirePermissions(sender, canUnfreeze, senderPermsLevel);
        frozenLevel = 0;
        frozenUntil = 0;
        emit UnfreezeCompleted();
    }

    //BYPASS SUPPORT

    function getBypassPolicy(address target, uint256 value, bytes memory encodedFunction) public view returns (uint256 delay, uint256 requiredConfirmations) {
        BypassPolicy bypass = bypassPoliciesByTarget[target];
        if (address(bypass) == address(0) && encodedFunction.length > 4) {
            bypass = bypassPoliciesByMethod[encodedFunction.readBytes4(0)];
        }
        if (address(bypass) == address(0)) {
            bypass = defaultBypassPolicy;
        }
        return bypass.getBypassPolicy(target, value, encodedFunction);
    }

    function scheduleBypassCall(uint32 senderPermsLevel, address target, uint256 value, bytes memory encodedFunction) public {
        address sender = getSender();
        requirePermissions(sender, canExecuteBypassCall, senderPermsLevel);
        requireNotFrozen(senderPermsLevel);

        (uint256 delay, uint256 requiredConfirmations) = getBypassPolicy(target, value, encodedFunction);
        require(!blockAcceleratedCalls || delay >= delays[extractLevel(senderPermsLevel)], "Accelerated calls blocked - delay too short");
//        require(requiredConfirmations != uint256(- 1), "Call blocked by policy");
        // if delay == -1, default to level-configured delay
        if (delay == uint256(-1)) {
            delay = delays[extractLevel(senderPermsLevel)];
        }
        bytes32 bypassCallHash = Utilities.bypassCallHash(stateNonce, sender, senderPermsLevel, target, value, encodedFunction);
        pendingBypassCalls[bypassCallHash] = PendingChange(SafeMath.add(now, delay), sender, 0, 0);
        emit BypassCallPending(bypassCallHash, stateNonce, sender, senderPermsLevel, target, value, encodedFunction);

        stateNonce++;
    }

    function applyBypassCall(
        uint32 senderPermsLevel,
        address scheduler,
        uint32 schedulerPermsLevel,
        uint256 scheduledStateNonce,
        address target,
        uint256 value,
        bytes memory encodedFunction)
    public {
        address sender = getSender();
        requireParticipant(sender, senderPermsLevel);
        requireNotFrozen(senderPermsLevel);

        bytes32 bypassCallHash = Utilities.bypassCallHash(scheduledStateNonce, scheduler, schedulerPermsLevel, target, value, encodedFunction);
        PendingChange memory pendingBypassCall = pendingBypassCalls[bypassCallHash];
        require(pendingBypassCall.dueTime != 0, "apply called for non existent pending bypass call");
        require(now >= pendingBypassCall.dueTime, "apply called before due time");
        delete pendingBypassCalls[bypassCallHash];
        bool success = execute(target, value, encodedFunction);
        emit BypassCallApplied(bypassCallHash, success);
        stateNonce++;
    }

    function cancelBypassCall(
        uint32 senderPermsLevel,
        address scheduler,
        uint32 schedulerPermsLevel,
        uint256 scheduledStateNonce,
        address target,
        uint256 value,
        bytes memory encodedFunction)
    public {
        address sender = getSender();
        requirePermissions(sender, canCancelBypassCall, senderPermsLevel);
        requireNotFrozen(senderPermsLevel);

        bytes32 bypassCallHash = Utilities.bypassCallHash(scheduledStateNonce, scheduler, schedulerPermsLevel, target, value, encodedFunction);
        PendingChange memory pendingBypassCall = pendingBypassCalls[bypassCallHash];
        require(pendingBypassCall.dueTime != 0, "cancel called for non existent pending bypass call");
        delete pendingBypassCalls[bypassCallHash];
        emit BypassCallCancelled(bypassCallHash, sender);

        stateNonce++;
    }

    function executeBypassCall(uint32 senderPermsLevel, address target, uint256 value, bytes memory encodedFunction) public {
        address sender = getSender();
        requirePermissions(sender, canExecuteBypassCall, senderPermsLevel);
        requireNotFrozen(senderPermsLevel);
        require(!blockAcceleratedCalls, "Accelerated calls blocked");

        (uint256 delay, uint256 requiredConfirmations) = getBypassPolicy(target, value, encodedFunction);
//        require(requiredConfirmations != uint256(- 1), "Call blocked by policy");
        require(delay == 0, "Call cannot be executed immediately.");
        bool success = execute(target, value, encodedFunction);
        emit BypassCallExecuted(success);
        stateNonce++;
    }

    /*** Relay Recipient implementation **/

    function getRecipientBalance() public pure returns (uint256){
        return 0;
    }

    function preRelayedCall(bytes calldata) external pure returns (bytes32){
        return 0;
    }

    function postRelayedCall(bytes calldata, bool, uint256, bytes32) external {
    }

    /****** Moved over from the Vault contract *******/

    event FundsReceived(address sender, uint256 value);

    function() payable external {
        emit FundsReceived(msg.sender, msg.value);
    }

    //TODO
    function execute(address target, uint256 value, bytes memory encodedFunction) internal returns (bool success){
        (success,) = target.call.value(value)(encodedFunction);
        //TODO: ...
    }

    function _acceptCall(address from, bytes memory encodedFunction) view internal returns (uint256 res, bytes memory data){
        uint32 senderRoleRank = uint32(GsnUtils.getParam(encodedFunction, 0));
        if (isParticipant(from, senderRoleRank)) {
            return (0, "");
        }
        else {
            return (11, "Not vault participant");
        }
    }
}