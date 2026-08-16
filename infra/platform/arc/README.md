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

## This repository is public

That is the hard case, and it is the case we are in. Anyone can open a pull
request, and a pull request is arbitrary code plus a request to execute it.

The split that makes it safe:

| Trigger | Runs on | Cache access |
|---|---|---|
| `push` to `main` | self-hosted | read-write |
| PR from a branch in this repo | self-hosted | read-only |
| **PR from a fork** | **GitHub-hosted** | read-only, public frontend only |

Fork PRs never touch our hardware. GitHub-hosted runners are free for public
repositories, so contributors still get full CI — they just get it on
infrastructure GitHub isolates rather than ours.

Enforcement is layered, because any single one of these can be misconfigured:

- Repository setting: require approval for all outside collaborators' workflow
  runs. Note the default — approve a contributor once and their *later* PRs run
  automatically — is not sufficient on its own.
- Workflow-level: self-hosted jobs gated on
  `github.event.pull_request.head.repo.full_name == github.repository`.
- `pull_request_target` is banned outright. It runs base-branch workflow code
  with a writable token in the context of a fork's PR, and it is the single most
  common way self-hosted CI gets compromised.
- Network-level: the read-write Buildbarn frontend is simply unreachable from
  the runner namespace, so a workflow that slips through still cannot poison the
  cache.

While the cluster is being built, `.github/workflows/ci.yml` runs everything on
GitHub-hosted runners; the `push` job moves to self-hosted once there is
something to move it to.

The GitHub App is scoped to `silicon-org/foundry` and nothing else. Widening
that later is easy and safe; narrowing it after something has come to depend on
it is neither.
