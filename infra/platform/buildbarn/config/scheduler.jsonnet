// Matches actions to workers. Clients ask the frontend to execute; the frontend
// forwards here; workers pull work from here.
local common = import 'common.libsonnet';

{
  adminHttpServers: [{
    listenAddresses: [':7982'],
    authenticationPolicy: { allow: {} },
  }],
  // Where frontends submit work.
  clientGrpcServers: [{
    listenAddresses: [':8982'],
    authenticationPolicy: { allow: {} },
  }],
  // Where workers ask for it.
  workerGrpcServers: [{
    listenAddresses: [':8983'],
    authenticationPolicy: { allow: {} },
  }],
  buildQueueStateGrpcServers: [{
    listenAddresses: [':8984'],
    authenticationPolicy: { allow: {} },
  }],
  contentAddressableStorage: common.storage,
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,
  global: common.global,

  executeAuthorizer: { allow: {} },
  modifyDrainsAuthorizer: { allow: {} },
  killOperationsAuthorizer: { allow: {} },
  synchronizeAuthorizer: { allow: {} },

  actionRouter: {
    simple: {
      // Route on the platform properties the client asked for. This is what
      // makes //platforms:linux_arm64 in the build graph select a worker whose
      // runner advertises the same properties.
      platformKeyExtractor: { action: {} },
      invocationKeyExtractors: [
        { correlatedInvocationsId: {} },
        { toolInvocationId: {} },
      ],
      initialSizeClassAnalyzer: {
        defaultExecutionTimeout: '1800s',
        maximumExecutionTimeout: '7200s',
      },
    },
  },

  // If a client asks for a platform no worker serves, fail after this rather
  // than queueing forever. A build that hangs is harder to diagnose than one
  // that fails.
  platformQueueWithNoWorkersTimeout: '900s',
}
