/* global global */
// this is the class loaded by the account.html frame.
import Account from '../impl/Account'
import AccountApi from '../api/Account.api'
// https://developer.mozilla.org/en-US/docs/Web/API/Window/postMessage
let account
const verbose = false

// const enabledSites = {}
function initMessageHandler ({ window }) {
  console.log('initMessageHandler')
  if (!window) {
    throw new Error('missing {window}')
  }
  if (!window.localStorage) {
    throw new Error('missing {window.localStorage}')
  }

  account = new Account(window.localStorage)

  const onMessage = function onMessage ({ source, data }) {
    const { method, id, args: params } = data
    if (data === 'account-iframe-ping') {
      if (verbose) { console.log('got ping. resend "initialized" ') }

      // repeat "initialized"
      window.parent.postMessage('account-iframe-initialized', '*')
      return
    }
    if (typeof data.method !== 'string') {
      return
    }
    handleMessage({ source, method, id, params })
  }

  if (window.addEventListener) {
    // For standards-compliant web browsers
    window.addEventListener('message', onMessage, false)
  } else {
    window.attachEvent('onmessage', onMessage)
  }

  setImmediate(() => {
    console.log('AccountFrame initialized')
    // window.parent.postMessage('account-iframe-initialized', '*')
  })
}

async function handleMessage ({ source, method, id, params }) {
  // only accept methods defined in the API
  if (method === 'constructor' || !AccountApi.prototype[method]) {
    console.warn('invalid account message call: ', method)
    return
  }

  // enable is the only method allowed before prompting the use to enable
  // if ( method !== 'enable' ) {
  //   if ( enabledSites)
  // }

  // console.log("src=",source.location.href)
  const methodToCall = account[method]
  let response, error
  if (verbose) { console.log('iframe: called', id, method, params) }
  try {
    response = await methodToCall.apply(account, params)
  } catch (e) {
    error = e
  }
  if (verbose) { console.log('iframe: resp', id, error || response) }

  const val = (await account.getEmail() ? 'E' : ' ') +
    (await account.getOwner() ? 'O' : ' ')
  console.log('iframe value', val)
  document.getElementById('valueDiv').innerText = val

  source.postMessage({ id, response, error }, '*')
}

global.initMessageHandler = initMessageHandler