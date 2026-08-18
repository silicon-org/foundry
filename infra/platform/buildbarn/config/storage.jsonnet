// The blobs themselves. Nothing talks to this directly except the frontends.
local common = import 'common.libsonnet';

// How big the cache is belongs to the cluster, not to this file. A laptop cluster
// that `talos:down` destroys wants a few gigabytes on an emptyDir; a cloud
// cluster with a volume that outlives it wants as much as the volume holds. So
// the sizes arrive as environment variables, the way the worker's architecture
// and concurrency already do -- one substituted value being a smaller thing to
// maintain than a second copy of the configuration.
//
// Unset is an evaluation error rather than a default, deliberately: a cache that
// silently sized itself to a laptop on a cloud cluster is exactly the mistake
// this replaces.
local casSizeBytes = std.parseInt(std.extVar('CAS_SIZE_GIB')) * 1024 * 1024 * 1024;
local acSizeBytes = std.parseInt(std.extVar('AC_SIZE_MIB')) * 1024 * 1024;

// Buildbarn's local backend writes into fixed-size files that it manages as
// block devices, and the block *count* is not a free choice: one block is the
// largest blob the backend will store. It divides the file into old + current +
// new + spare blocks and refuses anything that will not fit in one of them.
//
// At 8 GiB over 38 blocks that ceiling was 215.6 MiB, and what found it was a
// JDK: the asset service stores every fetched archive as a blob, rules_java's
// javac toolchains all run on the newest JDK whatever language version is asked
// for, and its distribution is 232 MB. The error is "Failed to place blob into
// CAS" during a repository fetch, which reads like a permissions problem.
//
// Twenty-one blocks rather than thirty-eight, and the ceiling then follows the
// cache size: 390 MiB at 8 GiB, 2.7 GiB at 56. The cost is coarser eviction,
// since a block is the unit that gets dropped and there are fewer of them --
// which is a hit-rate question, where the ceiling was a correctness one.
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
    backend: blockDevice('/storage-cas', 64 * 1024 * 1024, casSizeBytes, 3),
    getAuthorizer: { allow: {} },
    putAuthorizer: { allow: {} },
    findMissingAuthorizer: { allow: {} },
  },

  actionCache: {
    backend: blockDevice('/storage-ac', 1024 * 1024, acSizeBytes, 1),
    getAuthorizer: { allow: {} },
    putAuthorizer: { allow: {} },
  },
}
