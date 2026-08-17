# Deliberately without a default. State is committed to a public repository, so
# the encryption is the only thing standing between this passphrase and anyone
# who clones it -- which makes strength here matter more than it usually would.
# PBKDF2 slows a guess down; it does not save a guessable one.
#
# Generate with `age-keygen` or any password manager, and store it beside the
# age key. See infra/platform/secrets/README.md.
variable "state_passphrase" {
  description = "Passphrase encrypting tofu state and plans. Set TF_VAR_state_passphrase."
  type        = string
  sensitive   = true

  # OpenTofu enforces a 16-character floor of its own, and it fires before this
  # does -- the encryption block is evaluated before variable validation. So
  # this only ever speaks between 16 and 23 characters. That is still worth
  # having, because 16 is a general-purpose default and this particular
  # ciphertext is published.
  validation {
    condition     = length(var.state_passphrase) >= 24
    error_message = "Use at least 24 characters: this protects a file published in a public git history."
  }
}

variable "hcloud_token" {
  description = "Hetzner Cloud API token, read/write. Set HCLOUD_TOKEN or TF_VAR_hcloud_token."
  type        = string
  sensitive   = true
}

# Hetzner scopes some resources to a datacenter (servers, primary IPs) and
# others to the location containing it (load balancers). Only the datacenter is
# configured, and the location is derived from it, so the two cannot be set to
# disagree -- a mismatch otherwise surfaces at apply time as a load balancer
# that cannot see its own targets.
#
# The datacenter is named outright rather than derived from a location, because
# no rule connects them: fsn1 has dc14, nbg1 has dc3, hel1 has dc2.
variable "datacenter" {
  description = "Hetzner datacenter. Must sit in a region offering CAX (arm64): fsn1, nbg1, hel1."
  type        = string
  default     = "fsn1-dc14"

  validation {
    condition     = can(regex("^(fsn1|nbg1|hel1)-dc[0-9]+$", var.datacenter))
    error_message = "CAX servers exist only in fsn1, nbg1 and hel1; anywhere else there is no arm64 to run on."
  }
}

locals {
  location = split("-", var.datacenter)[0]
}

variable "talos_snapshot_id" {
  description = "Snapshot printed by `bazel run //infra/talos:image`."
  type        = string
}

# Sizing. These are variables rather than literals so that growing the cluster
# is a value change and not a rewrite -- the point at which one control plane
# becomes three should not be an editing exercise.
variable "control_plane_count" {
  description = "Control planes. Three for a real etcd quorum; one is a demo that survives nothing."
  type        = number
  default     = 3

  validation {
    condition     = var.control_plane_count % 2 == 1
    error_message = "etcd needs an odd number of members; an even count adds cost without adding quorum."
  }
}

variable "control_plane_type" {
  description = "Server type for control planes. Must be arm64 (CAX) -- see infra/doc/architecture.md."
  type        = string
  default     = "cax21"
}

variable "worker_count" {
  description = "Build workers running Buildbarn's remote execution."
  type        = number
  default     = 1
}

variable "worker_type" {
  description = "Server type for workers. cax41 (16 vCPU / 32 GB) is the largest arm64 Hetzner offers."
  type        = string
  default     = "cax41"
}

variable "network_cidr" {
  description = "Private network. Carries all Kubernetes traffic; Tailscale carries only administration."
  type        = string
  default     = "10.0.0.0/16"
}

variable "node_subnet" {
  description = "Subnet the nodes get addresses from, inside network_cidr."
  type        = string
  default     = "10.0.1.0/24"
}

# Break-glass. Invariant #6 in infra/doc/architecture.md asks for a declarative
# path to the Talos and Kubernetes APIs that is committed but normally inactive,
# written before it is needed rather than during the outage that needs it.
#
# It is also how the cluster gets built in the first place: a node in
# maintenance mode has no tailnet yet, so something has to be able to reach
# 50000 to hand it its first configuration. That makes this genuinely dual-use,
# which is why it is a variable and not a comment in a runbook.
variable "admin_access_enabled" {
  description = "Allow admin_ipv4 to reach the Talos and Kubernetes APIs. Off once the tailnet works."
  type        = bool
  default     = false
}

variable "admin_ipv4" {
  description = "Single administrative address, CIDR form (e.g. 203.0.113.4/32). Only used when admin_access_enabled."
  type        = string
  default     = null

  validation {
    condition     = var.admin_ipv4 == null || can(cidrhost(coalesce(var.admin_ipv4, "0.0.0.0/32"), 0))
    error_message = "admin_ipv4 must be CIDR notation, for example 203.0.113.4/32."
  }
}
