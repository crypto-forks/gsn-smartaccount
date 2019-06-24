const Gatekeeper = artifacts.require("./Gatekeeper.sol");
const Vault = artifacts.require("./Vault.sol");
const Chai = require('chai');
const Web3 = require('web3');

const utils = require('./utils');

const expect = Chai.expect;

// const {createMockProvider, deployContract, getWallets, solidity} = ;
Chai.use(require('ethereum-waffle').solidity);
Chai.use(require('bn-chai')(web3.utils.toBN));

function getDelayedOpHashFromEvent(log) {
    let sender = log.args.sender;
    let opsNonce = log.args.opsNonce.toNumber();
    let encoded = log.args.operation;
    let encodedBuff = Buffer.from(encoded.slice(2), "hex");
    return utils.delayedOpHash(sender, opsNonce, encodedBuff);
}

contract.only('Gatekeeper', async function (accounts) {

    let gatekeeper;
    let vault;
    let level = 1;
    let from = accounts[0];
    let wrongaddr = accounts[1];
    let destinationAddresss = accounts[2];
    let adminA = accounts[3];
    let adminB = accounts[4];
    let adminB1 = accounts[5];
    let adminC = accounts[6];
    let amount = 100;
    let delay = 77;
    let startBlock;
    let web3;
    let expectedDelayedEventsCount = 0;

    before(async function () {
        gatekeeper = await Gatekeeper.deployed();
        vault = await Vault.deployed();
        web3 = new Web3(gatekeeper.contract.currentProvider);
        startBlock = await web3.eth.getBlockNumber();
        await gatekeeper.setVault(vault.address);
        await gatekeeper.setSpender(from);
        await gatekeeper.addParticipant(adminA, level);
        await gatekeeper.addParticipant(adminB, level);
        await gatekeeper.setDelay(delay);
    });

    async function getLastEvent(contract, event, expectedCount) {
        let delayedEvents = await contract.getPastEvents(event, {
            fromBlock: startBlock,
            toBlock: 'latest'
        });
        // If 'contract' changes, just make sure to take the right one
        assert.equal(delayedEvents.length, expectedCount);
        return delayedEvents[delayedEvents.length - 1].returnValues;
    }

    /* Positive flows */

    /* Plain send */
    it("should allow the owner to create a delayed ether transfer transaction", async function () {
        let res = await gatekeeper.sendEther(destinationAddresss, amount);
        expectedDelayedEventsCount++;
        let encodedABI = vault.contract.methods.applyDelayedTransaction(destinationAddresss, amount).encodeABI();
        let encodedPacked = utils.bufferToHex(utils.encodePackedBatch([encodedABI]));
        let log = res.logs[0];
        assert.equal(log.event, "DelayedOperation");
        assert.equal(log.address, vault.address);
        // Vault sees the transaction as originating from Gatekeeper
        // and it does not know or care which participant initiated it
        assert.equal(log.args.sender, gatekeeper.address);
        assert.equal(log.args.operation, encodedPacked);
    });

    it("should fail to execute a delayed transfer transaction if not enough funds", async function () {
        let addedLog = await getLastEvent(vault.contract, "DelayedOperation", expectedDelayedEventsCount);
        let balance = parseInt(await web3.eth.getBalance(vault.address));
        assert.equal(balance, 0);

        await utils.increaseTime(3600 * 24 * 2 + 10);

        await expect(
            vault.applyDelayedOpsPublic(gatekeeper.address, addedLog.operation, addedLog.opsNonce)
        ).to.be.revertedWith("Cannot transfer more then vault's balance");
    });

    it("just funding the vault", async function () {
        await web3.eth.sendTransaction({from: from, to: vault.address, value: amount * 10});
    });

    it("should allow the owner to execute a delayed transfer transaction after delay", async function () {

        let addedLog = await getLastEvent(vault.contract, "DelayedOperation", expectedDelayedEventsCount);
        let balanceSenderBefore = parseInt(await web3.eth.getBalance(vault.address));
        let balanceRecieverBefore = parseInt(await web3.eth.getBalance(destinationAddresss));
        assert.isAbove(balanceSenderBefore, amount);
        await utils.increaseTime(3600 * 24 * 2 + 10);

        let res = await vault.applyDelayedOpsPublic(gatekeeper.address, addedLog.operation, addedLog.opsNonce);
        let log = res.logs[0];

        assert.equal(log.event, "FundsKindaTransferred");
        assert.equal(log.args.destination, destinationAddresss);
        assert.equal(log.args.value, amount);

        let balanceSenderAfter = parseInt(await web3.eth.getBalance(vault.address));
        let balanceRecieverAfter = parseInt(await web3.eth.getBalance(destinationAddresss));
        assert.equal(balanceSenderAfter, balanceSenderBefore - amount);
        assert.equal(balanceRecieverAfter, balanceRecieverBefore + amount);
    });


    /* Canceled send, rejected send */

    it("should revert when trying to cancel a transfer transaction that does not exist", async function () {
        await expect(
            gatekeeper.cancelTransaction("0x123123")
        ).to.be.revertedWith("cannot cancel, operation does not exist");
    });

    [{address: from, title: "owner"}, {address: adminA, title: "admin"}].forEach((participant) => {
        it(`should allow the ${participant.title} to cancel a delayed transfer transaction`, async function () {
            let res1 = await gatekeeper.sendEther(destinationAddresss, amount);
            expectedDelayedEventsCount++;
            let hash = getDelayedOpHashFromEvent(res1.logs[0]);
            let res2 = await gatekeeper.cancelTransaction(hash, {from: participant.address});
            let log = res2.logs[0];
            assert.equal(log.event, "DelayedOperationCancelled");
            assert.equal(log.address, vault.address);
            assert.equal(log.args.hash, "0x" + hash.toString("hex"));
            assert.equal(log.args.sender, gatekeeper.address);
        });
    });

    it("should allow the admin to create a delayed config transaction", async function () {
        let encodedABI = gatekeeper.contract.methods.addParticipant(adminB1, level).encodeABI();
        let encodedPacked = utils.encodePackedBatch([encodedABI]);
        let res = await gatekeeper.sendBatch(encodedPacked);
        let log = res.logs[0];
        assert.equal(log.event, "DelayedOperation");
        assert.equal(log.address, gatekeeper.address);
        assert.equal(log.args.sender, from);
        assert.equal(log.args.operation, utils.bufferToHex(encodedPacked));
    });


    it("should store admins' credentials hashed", async function () {
        let hash = utils.bufferToHex(utils.participantHash(adminA, level));
        let isAdmin = await gatekeeper.participants(hash);
        assert.equal(true, isAdmin);
    });

    /* Rejected config change */
    it("should allow the admin to cancel a delayed config transaction", async function () {
        let log = await utils.extractLastDelayedOpsEvent(gatekeeper);
        let hash = getDelayedOpHashFromEvent(log);
        let res2 = await gatekeeper.cancelOperation(hash, {from: adminA});
        let log2 = res2.logs[0];
        assert.equal(log2.event, "DelayedOperationCancelled");
        assert.equal(log2.address, gatekeeper.address);
        assert.equal(log2.args.hash, "0x" + hash.toString("hex"));
        assert.equal(log2.args.sender, adminA);

        await utils.validateAdminsConfig([adminA, adminB, adminB1], [1, 1, 1], [true, true, false], gatekeeper);
    });

    it("should revert an attempt to delete admin that is not a part of the config", async function () {
        let encodedABI = await gatekeeper.contract.methods.removeParticipant(utils.participantHash(adminC, level)).encodeABI();
        let encodedPacked = utils.encodePackedBatch([encodedABI]);
        let res = await gatekeeper.sendBatch(encodedPacked);
        let log = res.logs[0];
        assert.equal(log.event, "DelayedOperation");
        await utils.increaseTime(3600 * 24 * 2 + 10);
        await expect(
            gatekeeper.applyBatch(res.logs[0].args.operation, res.logs[0].args.opsNonce.toString())
        ).to.be.revertedWith("there is no such participant");
    });

    it("should allow the admin to add another admin after a delay", async function () {
        let encodedABI = gatekeeper.contract.methods.addParticipant(adminC, level).encodeABI();
        let encodedPacked = utils.encodePackedBatch([encodedABI]);
        let res = await gatekeeper.sendBatch(encodedPacked);
        await expect(
            gatekeeper.applyBatch(res.logs[0].args.operation, res.logs[0].args.opsNonce.toString())
        ).to.be.revertedWith("called before due time");
        await utils.increaseTime(3600 * 24 * 2 + 10);
        let res2 = await gatekeeper.applyBatch(res.logs[0].args.operation, res.logs[0].args.opsNonce.toString());
        let log2 = res2.logs[0];
        let hash = utils.bufferToHex(utils.participantHash(adminC, level));
        assert.equal(log2.event, "ParticipantAdded");
        assert.equal(log2.args.participant, hash);
        await utils.validateAdminsConfig([adminA, adminB, adminB1, adminC], [1, 1, 1, 1], [true, true, false, true], gatekeeper);
    });

    it("should allow the admin to delete another admin after a delay", async function () {
        let encodedABI = await gatekeeper.contract.methods.removeParticipant(utils.participantHash(adminC, level)).encodeABI();
        let encodedPacked = utils.encodePackedBatch([encodedABI]);
        let res = await gatekeeper.sendBatch(encodedPacked);
        let log = res.logs[0];
        assert.equal(log.event, "DelayedOperation");
        await utils.increaseTime(3600 * 24 * 2 + 10);
        let res2 = await gatekeeper.applyBatch(res.logs[0].args.operation, res.logs[0].args.opsNonce.toString());
        assert.equal(res2.logs[0].event, "ParticipantRemoved");
        await utils.validateAdminsConfig([adminA, adminB, adminB1, adminC], [1, 1, 1, 1], [true, true, false, false], gatekeeper);

    });

    /* Admin replaced */
    it("should allow the admin to replace another admin after a delay", async function () {
        let encodedABI_add_adminB1 = gatekeeper.contract.methods.addParticipant(adminB1, level).encodeABI();
        let encodedABI_remove_adminB = gatekeeper.contract.methods.removeParticipant(utils.participantHash(adminB, level)).encodeABI();
        let encodedPacked = utils.encodePackedBatch([encodedABI_add_adminB1, encodedABI_remove_adminB]);
        let res = await gatekeeper.sendBatch(encodedPacked);

        await expect(
            gatekeeper.applyBatch(res.logs[0].args.operation, res.logs[0].args.opsNonce.toString())
        ).to.be.revertedWith("called before due time");

        await utils.increaseTime(3600 * 24 * 2 + 10);

        let res2 = await gatekeeper.applyBatch(res.logs[0].args.operation, res.logs[0].args.opsNonce.toString())

        assert.equal(res2.logs[0].event, "ParticipantAdded");
        assert.equal(res2.logs[1].event, "ParticipantRemoved");

        await utils.validateAdminsConfig([adminA, adminB, adminB1, adminC], [1, 1, 1, 1], [true, false, true, false], gatekeeper);
    });

    /* Owner loses phone*/
    it("should allow the admin to replace the owner after a delay");

    /* Owner finds the phone after losing it */
    it("should allow the owner to cancel an owner change");

    /* Owner finds the phone after losing it */
    it("should allow the admin to cancel an owner change");

    /* doomsday recover: all participants malicious */
    it("should allow the super-admin to lock out all participants, cancel all operations and replace all participants");

    /* Negative flows */

    /* Owner’s phone controlled by a malicious operator */
    it("should not allow the owner to cancel an owner change if an admin locks him out");

    /* Plain send - opposite */
    it("should not allow non-owner to create a delayed transaction", async function () {
        await expect(
            gatekeeper.contract.methods.sendEther(destinationAddresss, amount).send({from: wrongaddr})
        ).to.be.revertedWith("Only spender can perform send operations!");
    });

    /* Admin replaced - opposite  & Owner loses phone - opposite */
    it("should not allow non-admin to replace admins or owners");

    it("should not allow any operation to be called without a delay");

    it("?should store participants as a hashes to conceal real number of participants and their identities");


});