// Shared by every Buildbarn component.
{
  maximumMessageSizeBytes: 16 * 1024 * 1024,

  global: {
    diagnosticsHttpServer: {
      httpServers: [{
        listenAddresses: [':9980'],
        authenticationPolicy: { allow: {} },
      }],
      enablePrometheus: true,
      enablePprof: true,
      enableActiveSpans: true,
    },
  },

  // The single storage backend. Sharding is what the reference deployment does
  // and what this grows into under load; one shard is what the current load
  // justifies, and a sharding config with one shard in it is just a more
  // complicated way of writing this.
  storage: { grpc: { client: { address: 'storage:8981' } } },
}
