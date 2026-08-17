// Runs the action's command. It executes inside the runner *container*, so that
// container's image is the action environment -- the compilers and tools an
// action can see are the ones baked into it.
//
// That is the lever for EDA later: open-source tools can come through Bazel as
// action inputs, but anything multi-gigabyte or licence-restricted belongs in
// this image instead.
{
  buildDirectoryPath: '/worker/build',
  grpcServers: [{
    listenPaths: ['/worker/runner'],
    authenticationPolicy: { allow: {} },
  }],
}
