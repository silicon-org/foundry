resource "hcloud_placement_group" "control_plane" {
  name = "foundry-control-plane"
  type = "spread"
}

# Addresses are assigned rather than accepted, both public and private, so that
# every node's address is known before the node exists.
#
# That is what lets talconfig.yaml be a static file. The alternative is
# generating machine configuration from tofu outputs after apply, which means
# either codegen or environment substitution -- and a cluster whose configuration
# cannot be read without first running something to produce it. Fixing the
# addresses costs a few lines here and removes that problem rather than
# automating it.
#
# It also survives replacement: destroy and recreate a node and it comes back on
# the same addresses, so nothing downstream needs to be told.
resource "hcloud_primary_ip" "control_plane" {
  count = var.control_plane_count

  name        = "foundry-cp-${count.index + 1}"
  type        = "ipv4"
  location    = local.location
  auto_delete = false
}

resource "hcloud_primary_ip" "worker" {
  count = var.worker_count

  name        = "foundry-worker-${count.index + 1}"
  type        = "ipv4"
  location    = local.location
  auto_delete = false
}

# Servers boot the snapshot and then sit in maintenance mode, waiting for a
# configuration, because nothing here passes user_data.
#
# That is on purpose rather than an omission. Machine configuration is
# talhelper's, and it contains cluster secrets; handing it to tofu would put
# those in state and would collapse a boundary infra/doc/architecture.md calls
# out as a non-goal. Tofu owns machines and networks. Talhelper owns what runs
# on them.
resource "hcloud_server" "control_plane" {
  count = var.control_plane_count

  name               = "foundry-cp-${count.index + 1}"
  server_type        = var.control_plane_type
  image              = var.talos_snapshot_id
  datacenter         = var.datacenter
  placement_group_id = hcloud_placement_group.control_plane.id
  firewall_ids       = [hcloud_firewall.nodes.id]

  labels = {
    cluster = "foundry"
    role    = "control-plane"
  }

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.control_plane[count.index].id

    # No IPv6. Not an objection to it -- it is that a second address family is a
    # second set of firewall rules, routes and failure modes, and nothing here
    # needs one yet.
    ipv6_enabled = false
  }

  # .11 upward, leaving the bottom of the subnet to the gateway and to Hetzner.
  network {
    network_id = hcloud_network.cluster.id
    ip         = cidrhost(var.node_subnet, 11 + count.index)
  }

  # The subnet has to exist before an interface can be given an address in it.
  depends_on = [hcloud_network_subnet.nodes]

  lifecycle {
    # A new schematic produces a new snapshot ID, and acting on that here would
    # replace every control plane at once -- which is not an upgrade, it is an
    # outage with a rebuild afterwards.
    #
    # Talos upgrades in place: `talosctl upgrade --image factory.talos.dev/...`,
    # one node at a time, with etcd staying healthy throughout. The snapshot is
    # only ever the starting point.
    ignore_changes = [image]
  }
}

resource "hcloud_server" "worker" {
  count = var.worker_count

  name         = "foundry-worker-${count.index + 1}"
  server_type  = var.worker_type
  image        = var.talos_snapshot_id
  datacenter   = var.datacenter
  firewall_ids = [hcloud_firewall.nodes.id]

  labels = {
    cluster = "foundry"
    role    = "worker"
  }

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.worker[count.index].id
    ipv6_enabled = false
  }

  # .21 upward, so control planes and workers stay visually distinct in a subnet
  # that will be read far more often than it is edited.
  network {
    network_id = hcloud_network.cluster.id
    ip         = cidrhost(var.node_subnet, 21 + count.index)
  }

  depends_on = [hcloud_network_subnet.nodes]

  lifecycle {
    ignore_changes = [image]
  }
}
