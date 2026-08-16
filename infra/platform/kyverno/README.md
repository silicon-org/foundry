# Kyverno

Admission control. Backstop for the workload rules, so that a mistake in a Helm
chart's values cannot quietly grant a runner more than it should have.

Policies:

- Block privileged pods and privilege escalation.
- Block host namespaces (`hostPID`, `hostIPC`, `hostNetwork`) and host path
  mounts. In particular: never the host Docker socket.
- Require rootless containers (`runAsNonRoot`) in `arc-runners`.
- Enforce Pod Security Standards `restricted` on the runner namespace.

These duplicate protections that PSS and the Cilium policy already provide. That
is intentional — invariant #2 is the one an attacker attacks first, so it gets
defence in depth rather than a single control.
