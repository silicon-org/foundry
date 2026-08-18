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
        // From the environment, so the password stays in a Secret and this file
        // stays readable in git. std.extVar rather than shell-style
        // interpolation: jsonnet does not expand ${...}, it would be passed
        // through verbatim and fail at connect time as an unparseable
        // keyword/value.
        connectionString: std.extVar('BB_PORTAL_DATABASE_URL'),
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

    // What turns a set of invocations into a Build.
    //
    // A Build is not something Bazel reports. Bazel streams one invocation per
    // command, and the portal does the grouping: it evaluates the expression
    // below against the environment the invocation ran in -- Bazel puts the
    // whole client environment into the event stream as --client_env options --
    // and groups every invocation whose buildTags[buildKey] agree. So one CI
    // run that probes the cache, tests and scans is one Build with three
    // invocations, and nothing on the Bazel side has to say so.
    //
    // Locally none of the GITHUB_ variables exist, every field here resolves to
    // null, and null fields are dropped rather than written. A laptop build
    // looks exactly as it does today and belongs to no Build, which is right:
    // there is nothing to group it with.
    //
    // Derived from upstream's config/gh-actions.jmespath, trimmed to the tags
    // this repository has a use for.
    invocationMetadataExtractor: {
      expression: |||
        {
          "username": env.GITHUB_ACTOR || env.USER,
          "hostname": env.HOSTNAME,
          "sourceControls": [
            {
              "repo": env.GITHUB_REPOSITORY,
              "repoUrl": (env.GITHUB_SERVER_URL && env.GITHUB_REPOSITORY) && join('/', [env.GITHUB_SERVER_URL, env.GITHUB_REPOSITORY]) || `null`,
              "ref": env.GITHUB_REF,
              "commit": env.GITHUB_SHA,
              "commitUrl": (env.GITHUB_SERVER_URL && env.GITHUB_REPOSITORY && env.GITHUB_SHA) && join('/', [env.GITHUB_SERVER_URL, env.GITHUB_REPOSITORY, 'commit', env.GITHUB_SHA]) || `null`
            }
          ],
          "invocationTags": {
            "job": env.GITHUB_JOB
          },
          "buildTags": {
            "repo": env.GITHUB_REPOSITORY,
            "workflow": env.GITHUB_WORKFLOW,
            "build_id": (env.GITHUB_SERVER_URL && env.GITHUB_REPOSITORY && env.GITHUB_RUN_ID) && join('/', [env.GITHUB_SERVER_URL, env.GITHUB_REPOSITORY, 'actions', 'runs', env.GITHUB_RUN_ID]) || `null`
          }
        }
      |||,
    },

    // Which of those tags is the Build ID. Left unset -- as it was -- nothing is
    // ever attached to anything and the Builds page stays empty, however good
    // the extractor above is. That is the whole of why it was empty.
    //
    // The run URL rather than the bare run number, so the identity of a Build is
    // also a link back to the run that produced it, and so two repositories
    // could never collide on the same integer.
    buildKey: 'build_id',

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
