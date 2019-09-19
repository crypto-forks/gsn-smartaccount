package com.tabookey.safechannels

import com.tabookey.duplicated.EthereumAddress
import com.tabookey.duplicated.IKredentials
import com.tabookey.safechannels.addressbook.SafechannelContact
import com.tabookey.safechannels.platforms.InteractorsFactory
import com.tabookey.safechannels.platforms.VaultFactoryContractInteractor
import com.tabookey.safechannels.vault.VaultState
import com.tabookey.safechannels.vault.VaultStorageInterface
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Unit testing was much easier in JVM/Junit environment for me, so I propose we keep that there.
 * This tests use non-mocked interactor and run in a Node environment.
 */
class IntegrationTestSafechannelsJS {



    @Test
    fun testHello() {
        assertTrue(true)
    }

    val storage = object : VaultStorageInterface {
        override fun getAllOwnedAccounts(): List<IKredentials> {
            TODO("not implemented") //To change body of created functions use File | Settings | File Templates.
        }

        override fun generateKeypair(): IKredentials {
            val kreds = object : IKredentials {
                override fun getAddress(): EthereumAddress {
                    return "0x12345678901234567890"
                }
            }
            return kreds
        }

        override fun sign(transactionHash: String, address: String): String {
            TODO("not implemented") //To change body of created functions use File | Settings | File Templates.
        }

        override fun putVaultState(vault: VaultState): Int {
            TODO("not implemented") //To change body of created functions use File | Settings | File Templates.
        }

        override fun putAddressBookEntry(contact: SafechannelContact) {
            TODO("not implemented") //To change body of created functions use File | Settings | File Templates.
        }

        override fun getAllVaultsStates(): List<VaultState> {
            TODO("not implemented") //To change body of created functions use File | Settings | File Templates.
        }

        override fun getAddressBookEntries(): List<SafechannelContact> {
            TODO("not implemented") //To change body of created functions use File | Settings | File Templates.
        }

        override fun getStuff() {
            TODO("not implemented") //To change body of created functions use File | Settings | File Templates.
        }

        override fun putStuff() {
            TODO("not implemented") //To change body of created functions use File | Settings | File Templates.
        }

    }

    /**
     * Normally, the SDK will be called from within the pure JavaScript and therefore there is no need to have
     * a Kotlin version of the 'require' statements;
     * The problem with these tests is that they are run directly by Gradle/Mocha,
     * and Kotlin does not generate the 'require's.
     * The 'js' method will inject whatever you put in there directly to the corresponding generated JavaSctipt code.
     */
    @Test
    fun should_construct_sdk_and_keypair_correctly() {
        js("var VaultFactoryContractInteractor = require(\"js_foundation/src/js/VaultFactoryContractInteractor\");")
        val interactorsFactory = InteractorsFactory()
        val vaultFactoryContractInteractor = VaultFactoryContractInteractor()
        val sdk = SafeChannels(interactorsFactory, vaultFactoryContractInteractor, storage)
        val keypair = sdk.createKeypair()
        assertEquals(22, keypair.getAddress().length)
    }

    @Test
    fun should_deploy_new_vault_via_factory_interactor(){
        js("var VaultFactoryContractInteractor = require(\"js_foundation/src/js/VaultFactoryContractInteractor\");")
        val vaultFactoryContractInteractor = VaultFactoryContractInteractor()
        val newGatekeeper = vaultFactoryContractInteractor.deployNewGatekeeper()
        assertEquals(22, newGatekeeper.gatekeeper!!.length)
    }
}