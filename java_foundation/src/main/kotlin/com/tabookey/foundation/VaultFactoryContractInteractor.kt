package com.tabookey.foundation

import com.tabookey.duplicated.EthereumAddress
import com.tabookey.duplicated.IKredentials
import com.tabookey.foundation.generated.VaultFactory
import org.web3j.crypto.Credentials
import org.web3j.protocol.Web3j
import org.web3j.tx.gas.DefaultGasProvider
import org.web3j.tx.gas.EstimatedGasProvider

open class VaultFactoryContractInteractor(
        private val vaultFactoryAddress: String,
        private val web3j: Web3j,
        private val credentials: Credentials) {

    companion object{
        suspend fun connect(credentials: IKredentials, vaultFactoryAddress: String, ethNodeUrl: String, networkId: Int): VaultFactoryContractInteractor
        {
            TODO()
        }
        suspend fun deployNewVaultFactory(from: EthereumAddress, ethNodeUrl: String): String{
            TODO()
        }
    }


    private var provider: EstimatedGasProvider = EstimatedGasProvider(web3j, DefaultGasProvider.GAS_PRICE, DefaultGasProvider.GAS_LIMIT)
    private var vaultFactory: VaultFactory = VaultFactory.load(vaultFactoryAddress, web3j, credentials, provider)

    open suspend fun deployNewGatekeeper(): Response {
        val receipt = vaultFactory.newVault().send()
        val vaultCreatedEvents = vaultFactory.getVaultCreatedEvents(receipt)
        assert(vaultCreatedEvents.size == 1)
        val event = vaultCreatedEvents[0]
        return Response(receipt.transactionHash, event.sender, event.gatekeeper, event.vault)
    }
}