// Maps URIs to CAS digests, so a repository archive is downloaded once for the
// whole cluster rather than once per runner.
//
// Remote execution moves actions, not repository rules. Every runner still
// resolves the module graph and downloads every external repository itself, and
// the hermetic toolchain made that graph considerably larger -- llvm-project,
// glibc, libcxx, compiler-rt. This is the only mechanism that moves those
// downloads off the client.
local common = import 'common.libsonnet';

{
  // Fetched bodies go in the CAS, so actions can read them as ordinary blobs.
  contentAddressableStorage: common.storage,

  // The URI-to-digest mapping lives in the Action Cache. Written by this
  // service talking to storage directly, never by a client -- which is what
  // keeps it compatible with clients that are refused Action Cache writes.
  assetCache: {
    actionCache: common.storage,
  },

  fetcher: {
    http: {},
  },

  grpcServers: [{
    listenAddresses: [':8985'],
    authenticationPolicy: { allow: {} },
  }],

  global: common.global,
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,

  // Both allowed, and the push half is not optional however much it looks it.
  //
  // Denying push seemed right by analogy with the Action Cache: a push asserts
  // "this URI has these bytes" and nothing verifies the claim. But the caching
  // fetcher records its own result through the same path, so denying push does
  // not stop clients asserting anything -- it stops the service storing what it
  // just downloaded, and every fetch fails with PERMISSION_DENIED after the
  // bytes have already been retrieved.
  //
  // What actually contains a poisoned mapping is Bazel: the qualifiers on each
  // request carry checksum.sri, taken from MODULE.bazel.lock, and a body that
  // does not match is rejected by the client. That is a real control and it is
  // the reason this is acceptable; it is also why an unpinned download would
  // not be protected by it.
  fetchAuthorizer: { allow: {} },
  pushAuthorizer: { allow: {} },

  // Which instance names this service may store fetched blobs under. It reads
  // as a push control and is not one: leaving it empty does not forbid clients
  // from pushing, it forbids the service from writing what it just downloaded,
  // and every fetch then fails with PERMISSION_DENIED after successfully
  // retrieving the bytes.
  //
  // The empty string is our instance name -- nothing here configures one, so
  // clients, frontends and workers all use the default.
  allowUpdatesForInstances: [''],
}
