// The two frontends differ in exactly one field. Writing them as one function
// makes that the only thing anyone has to check when auditing the read/write
// split -- rather than diffing two near-identical files and hoping.
local common = import 'common.libsonnet';

function(actionCachePutAuthorizer) {
  grpcServers: [{
    listenAddresses: [':8980'],
    authenticationPolicy: { allow: {} },
  }],
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,
  global: common.global,

  // The Content Addressable Store is writable from both frontends, on purpose.
  // A CAS blob is stored under the hash of its own contents, so writing to it
  // cannot change what anyone else reads: to poison a lookup for hash(X) you
  // would have to produce different bytes that also hash to X. Untrusted writes
  // here are a storage-quota question, not an integrity one.
  contentAddressableStorage: {
    backend: common.storage,
    getAuthorizer: { allow: {} },
    putAuthorizer: { allow: {} },
    findMissingAuthorizer: { allow: {} },
  },

  // The Action Cache is the opposite case, and the reason these two frontends
  // exist. It maps an action digest to the result of having run that action --
  // an unverifiable claim about what some command produced. Anyone who can
  // write it can make every later build trust their output. So on the read-only
  // frontend, they cannot.
  actionCache: {
    backend: {
      completenessChecking: {
        backend: common.storage,
        maximumTotalTreeSizeBytes: 64 * 1024 * 1024,
      },
    },
    getAuthorizer: { allow: {} },
    putAuthorizer: actionCachePutAuthorizer,
  },
}
