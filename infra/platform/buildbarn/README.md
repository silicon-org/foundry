# Buildbarn

Bazel remote execution and caching. Apache-2.0, no vendor lock-in, and the
reason the rest of this cluster exists.

Five deployments: `storage` holds the blobs, two frontends sit in front of it,
`scheduler` matches actions to workers, and `worker` runs them. Nothing talks to
storage directly — it has no opinion about who may do what, because that
decision belongs at the edge, where the caller's trust level is known.

## The read/write split

The Action Cache maps an action digest to a claim about what running that action
produced. Nobody can verify that claim after the fact, so anyone who can write
the Action Cache can make every later build trust their output. That is a supply
chain compromise dressed as a build speedup.

So there are two frontends:

| | Action Cache | CAS |
|---|---|---|
| `frontend-rw` | read + write | read + write |
| `frontend-ro` | **read only** | read + write |

The CAS stays writable from both on purpose. A CAS blob is stored under the hash
of its own contents, so writing to it cannot change what anyone else reads —
poisoning a lookup for `hash(X)` would mean producing different bytes that also
hash to `X`. Untrusted CAS writes are a storage-quota question, not an integrity
one.

Both configs come from one function in `config/frontend.libsonnet` that takes
the authorizer as its argument. Auditing the split is reading one line, not
diffing two near-identical files and hoping.

Bazel's `--noremote_upload_local_results` is a convenience, not the control. The
control is that `frontend-ro` refuses the write regardless of what the client
asks for. The second control — which lands with the runner network policy — is
that `frontend-rw` is not reachable from the namespace untrusted builds run in.
A flag is one typo from being wrong; a route that does not exist is not.

## Verifying the split

Do not take the table above on trust. Both frontends serve gRPC on 8980:

```
kubectl -n buildbarn port-forward svc/frontend-rw 8980:8980 &
kubectl -n buildbarn port-forward svc/frontend-ro 8981:8980 &

SALT=probe-$(date +%s)   # makes the actions unique, so nothing is pre-cached

# Read-only: writes are refused, so a second run gets no hits.
bazel clean && bazel build --action_env=CACHE_PROBE_SALT=$SALT \
  --remote_cache=grpc://localhost:8981 //infra/platform/buildbarn:cache_probe
bazel clean && bazel build --action_env=CACHE_PROBE_SALT=$SALT \
  --remote_cache=grpc://localhost:8981 //infra/platform/buildbarn:cache_probe

# Read-write: same actions, and the second run is served from cache.
bazel clean && bazel build --action_env=CACHE_PROBE_SALT=$SALT \
  --remote_cache=grpc://localhost:8980 //infra/platform/buildbarn:cache_probe
bazel clean && bazel build --action_env=CACHE_PROBE_SALT=$SALT \
  --remote_cache=grpc://localhost:8980 //infra/platform/buildbarn:cache_probe
```

The read-only runs must report eight locally-executed actions both times — never
a cache hit. The read-write second run must report `8 remote cache hit`. The absence of
the entry is the evidence; an error message on the write is not, since a
misconfigured endpoint can log complaints and store the entry anyway.

`//infra/platform/buildbarn:cache_probe` exists for exactly this. It is a probe,
not a build.

## Storage

One backend, filesystem-backed, sized for a laptop. The reference deployment
shards across several — a sharding config containing one shard is a more
complicated way of writing what this is, so it grows when there is load to
justify it, not before.

An initContainer creates the persistent state directories. bb-storage creates
its own block-device files but not the directory it keeps state in, so a fresh
volume crash-loops without it — a new PVC exactly as much as an emptyDir.

The local cluster overlay replaces the volume with an `emptyDir` and drops the
claim: that cluster has no StorageClass by design, because `bazel run
//infra/talos:down` deletes it.

## Remote execution

Five components. `storage` holds blobs, two frontends guard access, `scheduler`
matches actions to workers, and `worker` runs them.

The worker pod has two containers that must share a filesystem and a lifecycle:
`worker` materialises an action's inputs onto a volume and hands the command to
`runner` over a unix socket on that same volume. An init container copies the
`bb_runner` binary in, so the action environment image needs to know nothing
about Buildbarn.

**The runner container's image is the action environment.** Whatever an action
can execute is what is baked into it. That makes it the place where the toolchain
decision below gets implemented.

To use it:

```
kubectl -n buildbarn port-forward svc/frontend-rw 8980:8980 &
bazel build --config=remote --remote_executor=grpc://localhost:8980 //...
```

`--config=remote` adds `--extra_execution_platforms=//platforms:linux_arm64`,
whose `exec_properties` must match what the worker advertises in
`config/worker.jsonnet` **exactly**. Two things about that matching are worth
knowing, because both fail far from their cause:

- Properties must be **lexicographically sorted by name**. Buildbarn rejects a
  worker registration that is not, and the symptom appears at the other end of
  the system as "no workers exist for platform".
- A mismatch does not fall back to local execution. It queues until
  `platformQueueWithNoWorkersTimeout` expires, which is why that timeout is set
  rather than left infinite.

Confirm work really is leaving the machine by reading the worker log: each
action produces an `ExecuteResponse` naming the pod and node that ran it,
alongside CPU time and peak RSS.

## What remote execution will and will not move

Worth writing down before designing workers, because the intuition is wrong in a
useful way.

Remote execution moves **actions**. It does not move repository rules.
`http_archive`, `http_file` and module extensions run on the client, during
loading and analysis, in every version of Bazel. So a CI runner under remote
execution still checks out the source, downloads every external repository,
builds the action graph, and uploads missing inputs to the CAS. Only execution
goes elsewhere.

| Runner resource | Effect of remote execution |
|---|---|
| CPU | Collapses. Compilation and simulation move to workers. |
| Output disk and network | Collapses with `--remote_download_minimal`; outputs stay in the CAS. |
| Input and repository network | Unchanged. |
| Memory | Unchanged. The action graph still lives in the runner's RAM. |

The runner becomes CPU-thin while staying network- and memory-bound, so
repository fetching becomes a larger share of its work, not a smaller one. The
only mechanism that moves repository downloads off the client is the [Remote
Asset API](https://github.com/bazelbuild/remote-apis/blob/master/build/bazel/remote/asset/v1/remote_asset.proto),
via `--experimental_remote_downloader` and a service such as
[bb-remote-asset](https://github.com/buildbarn/bb-remote-asset). Note that
Buildbarn's own reference deployment does not include it, and the Bazel flag is
still marked experimental, so it is a considered choice rather than an obvious
one.

## Where toolchains live

Remote execution forces this decision to be explicit, and it matters more than
where the repository cache lives.

**As Bazel external repositories.** The client downloads the tool and uploads it
to the CAS; actions receive it as an input. The tool version is part of the
build graph, so builds are hermetic and reproducible. This is the right choice
for Verilator, Yosys, OpenROAD and anything else that is freely redistributable.

**Baked into the worker image**, selected through platform properties. The
client never touches it. This is unavoidable for multi-gigabyte commercial EDA
tools, and for anything license-restricted that must not be copied into a CAS.

The second option also drags in a networking requirement: commercial tools
generally need to reach a license server, so workers cannot be given the same
blanket egress denial as runners. That exception should be written as narrowly
as the license server allows.
