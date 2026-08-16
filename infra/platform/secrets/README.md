# Secrets

SOPS + age. Secrets are committed **encrypted** and decrypted in-cluster by the
Flux SOPS integration. Plaintext never enters git; `.gitignore` blocks the usual
accident paths.

SOPS over External Secrets Operator: no external secret store to run, secure and
depend on. Revisit if a second cluster or a real team makes key distribution the
bigger problem.

What lives here:

- An age key pair, with the private half held outside the repo (and outside the
  cluster's own backups).
- `.sops.yaml` creation rules so `sops` picks the right recipients automatically
  by path.
- The Flux `SecretRef` wiring so `Kustomization`s decrypt on apply.

Secrets that will live here: the ARC GitHub App private key, the Cloudflare
DNS-01 token, the Tailscale OAuth client, and the Hetzner API token if any
in-cluster controller ever needs it.

Related: etcd encryption-at-rest is a Talos machine-config concern, not a Flux
one — see `../../talos/`.
