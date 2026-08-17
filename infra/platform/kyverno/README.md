# Kyverno

Not deployed, and currently not needed.

The policies originally planned here — block privileged pods, block host
namespaces, require rootless — are already enforced by the Pod Security
Standards `restricted` label on `arc-runners`. That check runs in the API server
on every pod creation. Adding an admission controller to repeat it would be
motion rather than defence in depth.

What would justify Kyverno is something PSS cannot express:

- **Image provenance.** Only images from registries we trust, referenced by
  digest rather than tag. That is a real supply-chain control and nothing here
  currently provides it.
- **Cluster-wide defaults**, so a namespace created without the right labels
  does not silently opt out of everything.
- **Mutation**, for instance injecting resource limits or security contexts
  rather than rejecting workloads that omit them.

Until one of those is worth having, this directory stays empty. An unused
controller is still a controller with cluster-wide admission rights.
