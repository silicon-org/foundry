resource "hcloud_placement_group" "control_plane" {
  name = "foundry-control-plane"
  type = "spread"
}

# Private addresses are chosen here; public ones are allocated by Hetzner.
#
# The private side is the one that matters, because it is what the cluster is
# made of -- etcd peers, the API server, kubelet -- and choosing it is what lets
# talconfig.yaml exist as a static file. Otherwise machine configuration could
# only be produced after apply, by codegen or environment substitution, and the
# cluster's own configuration could not be read without first running something
# to generate it.
#
# The public side cannot work that way, because Hetzner picks the address. What
# a primary IP buys is stability rather than predetermination: the address
# outlives the server it is attached to, so a destroyed and recreated node keeps
# its identity. Bootstrap reads these from `tofu output`, which is acceptable
# because they are only needed in the window before the tailnet exists.
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
