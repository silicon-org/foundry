# Buildbarn

Bazel remote cache. Apache-2.0, no vendor lock-in, and the reason the rest of
this cluster exists.

Three deployments: `storage` holds the blobs, and two frontends sit in front of
it. Nothing talks to storage directly — it has no opinion about who may do what,
because that decision belongs at the edge, where the caller's trust level is
known.

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

The read-only runs must report `8 darwin-sandbox` both times — never a cache
hit. The read-write second run must report `8 remote cache hit`. The absence of
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

## Not here yet

Remote **execution** — scheduler, workers, runner images, action platforms. Only
caching is running. Execution decisions are about worker sizing and action
environments, which is precisely what a Docker-on-a-Mac cluster cannot tell you
anything useful about.

Workers will be arm64, matching the cluster. That constrains the toolchain:
anything that must run under remote execution has to build and run on arm64.
