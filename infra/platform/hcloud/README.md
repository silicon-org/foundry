# Hetzner cloud controller and CSI

Two things Kubernetes cannot do for itself on a cloud it knows nothing about.

**The cloud controller manager** tells Kubernetes what a Node actually is: it
sets the provider ID, fills in internal and external addresses, and deletes the
Node object when the server behind it is gone. Without it, nodes come up
tainted `node.cloudprovider.kubernetes.io/uninitialized` and nothing schedules
— which is a deliberate Kubernetes behaviour, not a bug, and it is why
`cluster.externalCloudProvider.enabled` is set in the Talos patch. That flag and
this deployment are two halves of one decision: enabling it without deploying
this leaves a cluster that never schedules anything, and deploying this without
enabling it leaves a controller with no authority.

**The CSI driver** turns a PersistentVolumeClaim into a Hetzner volume and
attaches it to whichever node needs it. Buildbarn's storage is the reason it is
here: a build cache on an `emptyDir` is a cache that starts cold after every
restart, and starting cold costs about five minutes of rebuilding on our
current graph.

Both need the Hetzner API, so both read the same token secret. It is committed
encrypted like everything else — see `../secrets/README.md`.

## The token is the same one tofu uses

That is worth stating because it is a wider grant than it first appears. This
token can create and delete servers, not just volumes: Hetzner project tokens
are not scoped per resource type, so "let the cluster manage its own volumes"
and "let the cluster delete its own nodes" are the same permission.

The containment is the project boundary. The token belongs to a project holding
only this cluster, so the worst case is bounded by what is in it. That is the
argument for a dedicated project rather than a shared one, and it is the reason
not to reuse a token from somewhere with other infrastructure in it.

## Volumes outlive the cluster, deliberately

`tofu destroy` removes servers; it does not remove volumes created through a
PersistentVolumeClaim, because tofu never knew about them. That is usually a
footgun and here it is the point: the cluster is torn down between work
sessions, and the cache surviving is what makes the next session start warm.

The corollary is that volumes are the one thing that accrues cost while nothing
is running, and the one thing that has to be deleted deliberately when the
cluster is retired for good.
