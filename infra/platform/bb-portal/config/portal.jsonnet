// Buildbarn Portal: what a build actually did, and what the cluster is doing.
//
// Three services, and they answer different questions:
//
//   bes        why was this build slow, what ran, what was cached
//   scheduler  what is queued right now, which workers are connected
//   browser    what is in the CAS and Action Cache, by digest
//
// The first is the one that pays for the Postgres below. The other two read
// live from the cluster and would need no database at all.
{
  global: {
    diagnosticsHttpServer: {
      httpServers: [{
        listenAddresses: [':9980'],
        authenticationPolicy: { allow: {} },
      }],
      enablePrometheus: true,
    },
  },

  // The web interface.
  httpServers: [{
    listenAddresses: [':8081'],
    authenticationPolicy: { allow: {} },
  }],

  // Reads blobs through the read-only frontend rather than the read-write one.
  // The portal only ever displays what is already there, so it has no reason to
  // hold a handle that can write the Action Cache.
  contentAddressableStorage: { grpc: { client: { address: 'frontend-ro:8980' } } },
  actionCache: { grpc: { client: { address: 'frontend-ro:8980' } } },
  initialSizeClassCache: { grpc: { client: { address: 'frontend-ro:8980' } } },
  fileSystemAccessCache: { grpc: { client: { address: 'frontend-ro:8980' } } },

  instanceNameAuthorizer: { allow: {} },
  maximumMessageSizeBytes: 16 * 1024 * 1024,

  besServiceConfiguration: {
    // Where Bazel sends its Build Event Protocol stream, via --bes_backend.
    grpcServers: [{
      listenAddresses: [':8082'],
      authenticationPolicy: { allow: {} },
      maximumReceivedMessageSizeBytes: 16 * 1024 * 1024,
    }],

    database: {
      postgres: {
        connectionString: '${BB_PORTAL_DATABASE_URL}',
      },
      connectionPoolConfiguration: {
        maxOpenConnections: 10,
        maxIdleConnections: 10,
        connectionMaxLifetime: '120s',
        connectionMaxIdleTime: '30s',
      },
    },

    // Retained for a week, cleaned every minute. Build history is diagnostic
    // rather than a record: the interesting question is almost always about a
    // build from the last few days, and unbounded retention on a 10GB volume
    // fails at the least convenient moment.
    databaseCleanupConfiguration: {
      cleanupInterval: '60s',
      invocationMessageTimeout: '3600s',
      invocationRetention: '604800s',
    },

    // Per-target detail, not per-action. Action-level data is far larger and
    // the questions we have -- which target was slow, what missed cache -- are
    // answered at target granularity.
    saveDataLevel: { basicAndTarget: {} },

    minEventBatchDuration: '0.1s',
    enableBepFileUpload: true,
  },

  schedulerServiceConfiguration: {
    buildQueueStateClient: { address: 'scheduler:8984' },
    // Killing an operation is a write, and nothing about a read-only dashboard
    // should be able to do it.
    killOperationsAuthorizer: { deny: {} },
    listOperationsPageSize: 500,
  },

  frontendServiceConfiguration: {
    frontendSource: { embedded: {} },
    frontendConfig: {
      companyName: 'foundry',
      grpcBackendUrl: 'grpc://localhost:8082',
      featureFlags: {
        home: { fileUpload: {}, instructions: {} },
        bes: { pageBuilds: {}, pageInvocations: {}, pageTargets: {}, pageTests: {}, pageTrends: {} },
      },
    },
  },
}
