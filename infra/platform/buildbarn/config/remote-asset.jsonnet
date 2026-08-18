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

  // Fetching is allowed; pushing is not. Push lets a client assert "this URI
  // has these bytes" without anything verifying it, which is the same
  // unverifiable claim the Action Cache split exists to contain -- and here it
  // would poison a dependency rather than a build result.
  fetchAuthorizer: { allow: {} },
  pushAuthorizer: { deny: {} },

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
