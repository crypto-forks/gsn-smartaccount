package com.tabookey.safechannels.vault

import com.tabookey.duplicated.VaultParticipantTuple
import com.tabookey.duplicated.VaultPermissions
import com.tabookey.safechannels.platforms.VaultFactoryContractInteractor
import com.tabookey.safechannels.addressbook.EthereumAddress
import com.tabookey.safechannels.platforms.InteractorsFactory

/**
 * Class represents the local state of the Vault before it has been deployed.
 * It can be converted to the [DeployedVault] once by deploying it to the blockchain.
 */
class VaultConfigBuilder(
        private val interactorsFactory: InteractorsFactory,
        private val factoryContractInteractor: VaultFactoryContractInteractor,
        storage: VaultStorageInterface,
        vaultState: VaultState)
    : SharedVaultInterface(storage, vaultState) {

    constructor(
            interactorsFactory: InteractorsFactory,
            factoryContractInteractor: VaultFactoryContractInteractor,
            owner: EthereumAddress,
            storage: VaultStorageInterface,
            initialDelays: List<Int>) : this(interactorsFactory, factoryContractInteractor, storage, VaultState()) {

        vaultState.addLocalChange(LocalVaultChange.initialize())
        vaultState.addLocalChange(LocalVaultChange.changeOwner(owner))
        vaultState.activeParticipant = VaultParticipantTuple(VaultPermissions.OWNER_PERMISSIONS, 1, owner)
    }

    /**
     * Blocks for as the deployment time and then returns the [DeployedVault] instance with the correct initial config
     */
    fun deployVault(): DeployedVault {
        val deploymentResult = factoryContractInteractor.deployNewGatekeeper()
        val participant = vaultState.activeParticipant
        // TODO: anything but this!!!
        val kreds = storage.getAllOwnedAccounts().first { it.getAddress() == vaultState.activeParticipant.address }
        val interactor = interactorsFactory.interactorForVault(
                kreds,
                deploymentResult.vault!!,
                deploymentResult.gatekeeper!!,
                participant)
        return DeployedVault(interactor, storage, vaultState)
    }


}