// Fetches actions from the scheduler, materialises their inputs, and hands them
// to the runner over a unix socket on the shared volume.
local common = import 'common.libsonnet';

{
  blobstore: {
    contentAddressableStorage: common.storage,
    actionCache: common.storage,
  },
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,
  scheduler: { address: 'scheduler:8983' },
  global: common.global {
    setUmask: { umask: 0 },
  },

  buildDirectories: [{
    native: {
      buildDirectoryPath: '/worker/build',
      cacheDirectoryPath: '/worker/cache',
      maximumCacheFileCount: 10000,
      maximumCacheSizeBytes: 1024 * 1024 * 1024,
      cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
    },
    runners: [{
      endpoint: { address: 'unix:///worker/runner' },
      // One action at a time. This cluster is a laptop; concurrency here is a
      // number to tune against real hardware, not to guess at.
      concurrency: 1,
      // What this worker advertises. A client asking for exactly these
      // properties lands here; anything else waits for a worker that matches.
      platform: {
        properties: [
          { name: 'OSFamily', value: 'linux' },
          { name: 'ISA', value: 'arm64' },
        ],
      },
      workerId: {
        pod: std.extVar('POD_NAME'),
        node: std.extVar('NODE_NAME'),
      },
    }],
  }],

  inputDownloadConcurrency: 10,
  outputUploadConcurrency: 11,
  directoryCache: {
    maximumCount: 1000,
    maximumSizeBytes: 1000 * 1024,
    cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
  },
}
