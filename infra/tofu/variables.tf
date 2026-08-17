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
  description = "Hetzner datacenter. European sites only: fsn1, nbg1, hel1."
  type        = string
  default     = "fsn1-dc14"

  # EU only. Not a technical constraint -- the dedicated line is sold in Ashburn,
  # Hillsboro and Singapore too -- but the US sites price the shared tiers at
  # roughly three times the European rate, and there is no reason to build in
  # another jurisdiction for a cluster whose users are here.
  validation {
    condition     = can(regex("^(fsn1|nbg1|hel1)-dc[0-9]+$", var.datacenter))
    error_message = "Use a European datacenter: fsn1, nbg1 or hel1."
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

# ccx13 is 2 dedicated cores and 8 GB. Dedicated rather than shared not because
# a control plane needs guaranteed cores, but because Hetzner's shared tiers
# (cx23, cx33, cx43) were unbuyable when this was written -- they sell out and
# come back within minutes, which is fine for a hobby VM and useless for
# something a cluster's existence depends on.
variable "control_plane_type" {
  description = "Server type for control planes. Dedicated (ccx) because the shared tiers are rarely in stock."
  type        = string
  default     = "ccx13"
}

variable "worker_count" {
  description = "Build workers running Buildbarn's remote execution."
  type        = number
  default     = 1
}

# The build worker, and the bulk of the bill: ccx33 is 8 dedicated cores and
# 32 GB at about EUR 0.24/hour. Dedicated cores matter here in a way they do not
# for the control planes, since this runs compilation and a noisy neighbour is
# indistinguishable from a slow build.
#
# Scale by adding workers rather than by growing this one. Buildbarn schedules
# across workers, so two nodes are worth more than one twice the size -- and
# they can be bought when the larger single instance cannot.
variable "worker_type" {
  description = "Server type for build workers. Dedicated cores, because this runs compilation."
  type        = string
  default     = "ccx33"
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
# path to the Talos and Kubernetes APIs, written before it is needed rather than
# during the outage that needs it.
#
# It is also how the cluster gets built at all: a node in maintenance mode has
# no tailnet yet, so something has to reach 50000 to hand it its first
# configuration. Genuinely dual-use, which is why it is a variable rather than a
# note in a runbook.
#
# Note what is *not* here: an address. The mechanism is committed and the value
# never is, because an administrator's address is usually dynamic -- and a rule
# pinned to whatever it was on the day it was written is stale precisely when it
# is needed. So this is opened at the moment of use, from wherever you are:
#
#   tofu apply -var="admin_access_enabled=true" \
#              -var="admin_ipv4=$(curl -s https://ifconfig.me)/32"
#
# That still works during a tailnet outage, because the Hetzner API is a
# separate control plane: it does not depend on the cluster, the VPN, or
# anything else that might be the thing that broke.
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
