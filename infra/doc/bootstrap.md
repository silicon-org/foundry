# Building a cluster from nothing

Four commands. Everything else comes from git.

This is the irreducible part: you cannot use GitOps to install GitOps, and you
cannot schedule the thing that installs the CNI onto a cluster that has no CNI.
Every step below exists because of one of those two problems. If a fifth step
ever appears here, something has gone wrong.

Takes about four minutes end to end.

## Before you start

- A running Docker daemon (for the local cluster).
- The age key at `~/.config/sops/age/foundry.txt`. See
  [secrets](../platform/secrets/README.md).
- A GitHub token with `repo` scope. `gh auth token` works.

## 1. Create the cluster

```
bazel run //infra/talos:up
```

Talos in Docker, one control plane and one worker. Machine configs come from
`infra/talos/patches/`.

The nodes will report `NotReady` and stay that way. That is correct: Talos is
configured with no CNI, so nothing can be scheduled until step 2. A cluster that
comes up `Ready` here would mean something else installed a network.

The kubeconfig is merged into `~/.kube/config` automatically, under the context
`admin@foundry`.

## 2. Install the CNI

```
bazel run //infra/platform/cilium:bootstrap
```

This is a plain `helm upgrade --install`, reading the same `values.yaml` that
the Flux HelmRelease uses. Flux takes ownership on its first reconcile: same
release name, same namespace, same values, so it performs an ordinary upgrade
rather than fighting over the resource.

Nodes go `Ready` within a minute or so. Check with `kubectl get nodes`.

## 3. Give the cluster its decryption key

```
kubectl create namespace flux-system
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=$HOME/.config/sops/age/foundry.txt
```

Create the namespace first. Flux would create it in step 4, but the secret has
to exist before Flux reconciles anything encrypted, and doing it in this order
avoids a window where the ARC Kustomization fails because it cannot decrypt the
GitHub App credentials.

This is the only secret in the whole system created by hand, and it has to be:
it is the key Flux would need in order to decrypt itself. Everything else lives
in git, encrypted.

## 4. Bootstrap Flux

```
export GITHUB_TOKEN="$(gh auth token)"
flux bootstrap github \
  --owner=silicon-org \
  --repository=foundry \
  --branch=main \
  --path=infra/platform/clusters/local \
  --personal=false
```

Installs the Flux controllers, creates a read-only deploy key on the repository,
and commits its own manifests under
`infra/platform/clusters/local/flux-system/`. It is idempotent — running it
against a repository that already has those manifests just reinstalls the
controllers.

## That is all

Everything else reconciles from git. Watch it happen:

```
flux get kustomizations -A
```

Cilium, then Buildbarn and ARC once Cilium is ready, in that order because
`dependsOn` says so. All four report `True` after roughly 75 seconds.

## Checking it worked

```
kubectl get pods -A
kubectl -n arc-runners get autoscalingrunnerset
```

The runner scale set should reach phase `Running` with a `runner-scale-set-id`.
That means it authenticated to GitHub with the decrypted App credentials, which
transitively proves steps 3 and 4 both worked.

To check that etcd encryption is on, and the read/write cache split holds, see
[talos](../talos/README.md) and
[buildbarn](../platform/buildbarn/README.md).

## Tearing down

```
bazel run //infra/talos:down
```

Deletes the containers and the network. Nothing survives, which is the point of
the local environment — it is meant to be rebuilt, not repaired.

The GitHub side does survive: the Flux deploy key and the ARC runner scale set
registration both persist. Both are reused on the next bootstrap, so no cleanup
is needed.

## If the runner scale set wedges

Rare, and worth recognising because it presents as a hang rather than an error:
jobs queue forever and nothing reports a failure.

```
kubectl -n arc-runners get autoscalingrunnerset -o custom-columns=\
'NAME:.metadata.name,PHASE:.status.phase,ID:.metadata.annotations.runner-scale-set-id'
```

Phase `Outdated` with no ID, no listener pod in `arc-systems`, and no
`EphemeralRunnerSet` means the controller has torn everything down and will not
rebuild it (actions/actions-runner-controller#4595). Delete the object and force
Helm to recreate it:

```
kubectl -n arc-runners delete autoscalingrunnerset foundry-arm64
flux reconcile helmrelease foundry -n arc-runners --force
```

The usual cause is a runner image version GitHub has deprecated. Check the pin
in `infra/platform/arc/runner-scale-set.yaml` against the current
[runner releases](https://github.com/actions/runner/releases) before assuming
anything subtler.
