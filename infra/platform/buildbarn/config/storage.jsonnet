// The blobs themselves. Nothing talks to this directly except the frontends.
local common = import 'common.libsonnet';

// Buildbarn's local backend writes into fixed-size files that it manages as
// block devices. Sizes are deliberately small here: this is a laptop, and a
// cache that outgrows its disk is a worse failure than one that evicts early.
//
// The block *count* is not a free choice, because one block is the largest blob
// this backend will store: it divides the file into old + current + new + spare
// blocks and refuses anything that cannot fit in one of them. At 8 GiB over 38
// blocks the ceiling was 215.6 MiB, and the failure that found it was a JDK --
// the asset service stores every fetched archive as a blob, rules_java's javac
// toolchains all run on the newest JDK whatever language version is asked for,
// and its distribution is 232 MB. What comes back is "Failed to place blob into
// CAS" during a repository fetch, which reads like a permissions problem.
//
// So: twenty-one blocks rather than thirty-eight, which puts the ceiling at
// 390 MiB and uses not one byte more disk. The cost is coarser eviction -- a
// block is the unit that gets dropped, and there are fewer of them -- which is a
// hit-rate question, where the ceiling was a correctness one. A generated
// XiangShan top is 139 MB, so this is not the last large blob to come through.
local blockDevice(dir, keyLocationMapSizeBytes, blocksSizeBytes, newBlocks) = {
  'local': {
    keyLocationMapOnBlockDevice: {
      file: {
        path: dir + '/key_location_map',
        sizeBytes: keyLocationMapSizeBytes,
      },
    },
    keyLocationMapMaximumGetAttempts: 16,
    keyLocationMapMaximumPutAttempts: 64,
    oldBlocks: 4,
    currentBlocks: 12,
    newBlocks: newBlocks,
    blocksOnBlockDevice: {
      source: {
        file: {
          path: dir + '/blocks',
          sizeBytes: blocksSizeBytes,
        },
      },
      spareBlocks: 2,
    },
    // Survives a restart. Without this the cache is cold every time a pod is
    // rescheduled, which makes hit-rate numbers meaningless.
    persistent: {
      stateDirectoryPath: dir + '/persistent_state',
      minimumEpochInterval: '300s',
    },
  },
};

{
  grpcServers: [{
    listenAddresses: [':8981'],
    authenticationPolicy: { allow: {} },
  }],
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,
  global: common.global,

  contentAddressableStorage: {
    backend: blockDevice('/storage-cas', 64 * 1024 * 1024, 8 * 1024 * 1024 * 1024, 3),
    getAuthorizer: { allow: {} },
    putAuthorizer: { allow: {} },
    findMissingAuthorizer: { allow: {} },
  },

  actionCache: {
    backend: blockDevice('/storage-ac', 1024 * 1024, 128 * 1024 * 1024, 1),
    getAuthorizer: { allow: {} },
    putAuthorizer: { allow: {} },
  },
}
