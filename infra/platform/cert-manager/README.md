# cert-manager

TLS issuance for in-cluster services.

`silicon-lang.org` has DNS at Cloudflare, so DNS-01 is the natural issuer: it
works for internal-only names that Let's Encrypt can never reach over HTTP-01,
which matters because nothing here is publicly routable.

Needs a Cloudflare API token scoped to `Zone:DNS:Edit` on that one zone, stored
SOPS-encrypted in `../secrets/`. Not a token with account-wide scope.

Note that services reachable only over the tailnet can instead use
Tailscale-issued certificates, which removes cert-manager from the critical path
entirely. Worth settling before anything depends on it.
