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
      // Must be lexicographically sorted by name. Buildbarn rejects the
      // worker's registration outright if it is not, and the symptom shows up
      // at the other end of the system as "no workers exist for platform".
      // ISA comes from the environment because the two clusters differ: the
      // local one is arm64 (Talos in Docker on Apple Silicon) and the Hetzner
      // one is x86. Everything else about this file is identical for both, and
      // one substituted value is a smaller difference to maintain than a second
      // copy of the worker configuration.
      //
      // An unset ISA is a jsonnet evaluation error, so the worker refuses to
      // start rather than registering as an architecture it cannot execute --
      // which would be far worse, since actions would be scheduled to it and
      // then fail in ways that look like compiler bugs.
      platform: {
        properties: [
          { name: 'ISA', value: std.extVar('ISA') },
          { name: 'OSFamily', value: 'linux' },
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
