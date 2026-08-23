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
    // One entry per size class this worker serves. Each registers with the
    // scheduler independently, so a single pod can offer several classes --
    // they share the runner socket, and only the advertised platform and the
    // concurrency differ.
    //
    // A large worker serves small actions too, and that is the point. Routing
    // only the heavy action to the large class left a 16-core node idle for a
    // whole build while a 2-concurrency worker ground through ten thousand
    // compiles: the elastic node has to contribute its cores to ordinary work
    // while it exists, or it is worth almost nothing.
    runners: [
      {
        endpoint: { address: 'unix:///worker/runner' },
        // How many actions this worker runs at once, from the environment
        // because it is a property of the machine, not of Buildbarn. One on a
        // laptop sharing a Docker VM with everything else; more on a node that
        // has nothing else to do.
        concurrency: std.parseInt(std.extVar('RUNNER_CONCURRENCY')),
        // What this worker advertises. A client asking for exactly these
        // properties lands here; anything else waits for a worker that matches.
        // Must be lexicographically sorted by name -- Buildbarn rejects the
        // registration outright otherwise, and the symptom appears at the far
        // end of the system as "no workers exist for platform".
        //
        // ISA comes from the environment because the two clusters differ: the
        // local one is arm64 and the Hetzner one is x86. An unset value is a
        // jsonnet evaluation error, so a worker refuses to start rather than
        // registering as an architecture it cannot execute -- which would be
        // far worse, since actions would be scheduled to it and then fail in
        // ways that look like compiler bugs.
        platform: {
          properties: [
            { name: 'ISA', value: std.extVar('ISA') },
            { name: 'OSFamily', value: 'linux' },
            { name: 'size', value: 'small' },
          ],
        },
        workerId: {
          pod: std.extVar('POD_NAME'),
          node: std.extVar('NODE_NAME'),
          size: 'small',
        },
      },
    ] + (
      // The large class, only where a machine can actually hold it. The
      // elaboration in //hardware/soc/xs_cluster/tb peaks at 24.24 GiB,
      // measured, so concurrency here is low by necessity rather than by
      // caution: two of them do not fit beside the small actions on a 64 GB
      // node.
      if std.extVar('SIZE') == 'large' then [{
        endpoint: { address: 'unix:///worker/runner' },
        concurrency: std.parseInt(std.extVar('LARGE_CONCURRENCY')),
        platform: {
          properties: [
            { name: 'ISA', value: std.extVar('ISA') },
            { name: 'OSFamily', value: 'linux' },
            { name: 'size', value: 'large' },
          ],
        },
        workerId: {
          pod: std.extVar('POD_NAME'),
          node: std.extVar('NODE_NAME'),
          size: 'large',
        },
      }] else []
    ),
  }],

  inputDownloadConcurrency: 10,
  outputUploadConcurrency: 11,
  directoryCache: {
    maximumCount: 1000,
    maximumSizeBytes: 1000 * 1024,
    cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
  },
}
