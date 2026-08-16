# Actions Runner Controller

Ephemeral GitHub Actions runners (`gha-runner-scale-set`), authenticated with a
GitHub App and scoped to `github.com/silicon-org`.

Outbound-only to GitHub, which is the whole point: self-hosted CI with zero
inbound ports.

## The threat model, stated plainly

Runners execute untrusted code. That is not a risk to mitigate, it is the job
description. Everything here follows from it:

- **Ephemeral pods.** One job, then the pod is gone. No state carries between
  jobs.
- **No standing secrets** in the runner environment. A job that needs a
  credential gets it scoped and short-lived.
- **No fork-PR execution.** Fork PRs run on GitHub-hosted runners or not at all.
- **No host Docker socket.** Ever. Rootless BuildKit or buildah instead.
- **Egress allow-list only** — DNS, GitHub FQDNs, the read-only Buildbarn
  frontend, and the dependency registries the real builds need. Enforced by
  Cilium default-deny on this namespace.

The GitHub App is scoped to `silicon-org/foundry` and nothing else. Widening
that later is easy and safe; narrowing it after something has come to depend on
it is neither.
