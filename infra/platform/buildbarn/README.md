# Buildbarn

Bazel remote execution and content-addressed cache. Apache-2.0, no vendor
lock-in, and the reason the rest of this cluster exists.

## The read/write split

Invariant #3: an untrusted build must be able to *read* the Action Cache but
never *write* it. Otherwise anyone who can run CI can poison the cache for
everyone, which is a supply-chain compromise wearing a build-performance
costume.

Two frontends, separated at the network layer rather than by configuration
alone, so that a misconfigured flag is not the only thing standing between an
attacker and cache writes:

- **read-write** — trusted builds (post-merge on `main`).
- **read-only** — everything else. AC `put` denied. This is the only Buildbarn
  endpoint the `arc-runners` egress allow-list contains.

Bazel-side, the read-only path is `--noremote_upload_local_results`; that is a
convenience, not the control. The control is that the read-write frontend is
unreachable from the runner namespace.

## Storage

Filesystem CAS to start — the simplest thing that works, and the early problems
worth surfacing are design problems, not object-storage operations. MinIO or
Hetzner Object Storage are the candidates once there is real cache-size data to
argue from.

## Workers

arm64, matching the cluster. Remote-execution worker platforms must match what
the actions actually need, so this constrains the hardware toolchain: anything
that must run under RE has to build and run on arm64.
