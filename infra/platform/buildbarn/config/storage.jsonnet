// The blobs themselves. Nothing talks to this directly except the frontends.
local common = import 'common.libsonnet';

// Buildbarn's local backend writes into fixed-size files that it manages as
// block devices. Sizes are deliberately small here: this is a laptop, and a
// cache that outgrows its disk is a worse failure than one that evicts early.
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
    oldBlocks: 8,
    currentBlocks: 24,
    newBlocks: newBlocks,
    blocksOnBlockDevice: {
      source: {
        file: {
          path: dir + '/blocks',
          sizeBytes: blocksSizeBytes,
        },
      },
      spareBlocks: 3,
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
