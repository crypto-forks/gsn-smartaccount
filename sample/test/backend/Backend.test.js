/* global describe before afterEach it */

import { Backend } from '../../src/js/backend/Backend'
import { assert } from 'chai'
import SMSmock from '../../src/js/mocks/SMS.mock'
import { hookBackend } from './testutils'
import { KeyManager } from '../../src/js/backend/KeyManager'
import { SmsManager } from '../../src/js/backend/SmsManager'
import crypto from 'crypto'
import { BackendAccount, AccountManager } from '../../src/js/backend/AccountManager'

const ethUtils = require('ethereumjs-util')
const abi = require('ethereumjs-abi')
const phone = require('phone')

describe('Backend', async function () {
  let backend
  const keypair = {
    privateKey: Buffer.from('20e12d5dc484a03c969d48446d897a006ebef40a806dab16d58db79ba64aa01f', 'hex'),
    address: '0x68cc521201a7f8617c5ce373b0f0993ee665ef63'
  }
  let smsProvider
  let smsManager
  let keyManager
  let accountManager
  const jwt = require('./testJwt').jwt
  let smsCode
  const phoneNumber = '+972541234567'
  const email = 'shahaf@tabookey.com'
  const audience = '202746986880-u17rbgo95h7ja4fghikietupjknd1bln.apps.googleusercontent.com'

  before(async function () {
    smsProvider = new SMSmock()
    smsManager = new SmsManager({ smsProvider, secretSMSCodeSeed: crypto.randomBytes(32) })
    keyManager = new KeyManager({ ecdsaKeyPair: keypair })
    accountManager = new AccountManager()

    backend = new Backend(
      {
        smsManager,
        audience,
        keyManager,
        accountManager
      })

    // hooking google-api so we don't actually send jwt tot their server
    hookBackend(backend)
  })
  describe('sms code generation', async function () {
    let ts
    let firstCode
    let formattedNumber
    before(async function () {
      formattedNumber = backend._formatPhoneNumber(phoneNumber)
      ts = backend.smsManager.getMinuteTimestamp({})
      firstCode = backend.smsManager.calcSmsCode(
        { phoneNumber: formattedNumber, email: email, minuteTimeStamp: ts })
    })
    afterEach(async function () {
      Date.now = Date.nowOrig
      delete Date.nowOrig
    })
    it('should generate the same sms code for calls within 10 minute window', function () {
      Date.nowOrig = Date.now
      Date.now = function () {
        return Date.nowOrig() + 5e5 // ~9 minutes in the future
      }
      // calculate desired timestamp from a given sms code
      ts = backend.smsManager.getMinuteTimestamp({ expectedSmsCode: firstCode })
      const secondCode = backend.smsManager.calcSmsCode(
        { phoneNumber: formattedNumber, email: email, minuteTimeStamp: ts })
      assert.equal(firstCode, secondCode)
    })

    it('should generate different sms code for calls out of the 10 minute window', function () {
      Date.nowOrig = Date.now
      Date.now = function () {
        return Date.nowOrig() + 6e5 // = 10 minutes in the future
      }
      // calculate desired timestamp from a given sms code
      ts = backend.smsManager.getMinuteTimestamp({ expectedSmsCode: firstCode })
      const secondCode = backend.smsManager.calcSmsCode(
        { phoneNumber: formattedNumber, email: email, minuteTimeStamp: ts })
      assert.isTrue(parseInt(secondCode).toString() === secondCode.toString())
      assert.notEqual(firstCode, secondCode)
    })
  })

  describe('validatePhone', async function () {
    it('should throw on invalid phone number', async function () {
      const phoneNumber = '1243 '
      const invalidjwt = 'token'
      try {
        await backend.validatePhone({ jwt: invalidjwt, phoneNumber })
        assert.fail()
      } catch (e) {
        assert.equal(e.toString(), `Error: Invalid phone number: ${phoneNumber}`)
      }
    })

    it('should throw on invalid jwt token', async function () {
      const invalidjwt = 'invalid token'
      try {
        await backend.validatePhone({ jwt: invalidjwt, phoneNumber })
        assert.fail()
      } catch (e) {
        assert.equal(e.toString(), `Error: invalid jwt format: ${invalidjwt}`)
      }
    })

    it('should validate phone number', async function () {
      await backend.validatePhone({ jwt, phoneNumber })
      smsCode = backend.smsManager.getSmsCode(
        { phoneNumber: backend._formatPhoneNumber(phoneNumber), email: email })
      assert.notEqual(smsCode, undefined)
    })
  })

  describe('createAccount', async function () {
    it('should throw on invalid sms code', async function () {
      const wrongSmsCode = smsCode - 1
      try {
        await backend.createAccount({ jwt, smsCode: wrongSmsCode, phoneNumber })
        assert.fail()
      } catch (e) {
        assert.equal(e.toString(), `Error: invalid sms code: ${wrongSmsCode}`)
      }
    })

    it('should createAccount by verifying sms code', async function () {
      console.log('smsCode', smsCode)
      const accountCreatedResponse = await backend.createAccount({ jwt, smsCode, phoneNumber })
      const expectedSmartAccountId = abi.soliditySHA3(['string'], [email])
      assert.equal(accountCreatedResponse.smartAccountId, '0x' + expectedSmartAccountId.toString('hex'))

      const approvalData = accountCreatedResponse.approvalData
      assert.isTrue(ethUtils.isHexString(approvalData))
      const decoded = abi.rawDecode(['bytes4', 'bytes'],
        Buffer.from(accountCreatedResponse.approvalData.slice(2), 'hex'))
      const timestamp = decoded[0]
      let sig = decoded[1]
      sig = ethUtils.fromRpcSig(sig)
      let hash = abi.soliditySHA3(['bytes32', 'bytes4'],
        [Buffer.from(accountCreatedResponse.smartAccountId.slice(2), 'hex'), timestamp])
      hash = abi.soliditySHA3(['string', 'bytes32'], ['\x19Ethereum Signed Message:\n32', hash])
      const backendExpectedAddress = ethUtils.publicToAddress(ethUtils.ecrecover(hash, sig.v, sig.r, sig.s))
      assert.equal('0x' + backendExpectedAddress.toString('hex'), backend.keyManager.address())
      const accountId = await backend.getSmartAccountId({ email })
      const account = new BackendAccount(
        {
          accountId: accountId,
          email: email,
          phone: phone(phoneNumber),
          verified: true
        })
      const actualAccount = backend.accountManager.getAccountById({ accountId })
      assert.deepEqual(actualAccount, account)
    })
  })

  describe('addOperatorNow', async function () {

  })
})
