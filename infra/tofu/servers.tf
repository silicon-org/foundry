resource "hcloud_placement_group" "control_plane" {
  name = "foundry-control-plane"
  type = "spread"
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
  location           = var.location
  placement_group_id = hcloud_placement_group.control_plane.id
  firewall_ids       = [hcloud_firewall.nodes.id]

  labels = {
    cluster = "foundry"
    role    = "control-plane"
  }

  network {
    network_id = hcloud_network.cluster.id
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
  location     = var.location
  firewall_ids = [hcloud_firewall.nodes.id]

  labels = {
    cluster = "foundry"
    role    = "worker"
  }

  network {
    network_id = hcloud_network.cluster.id
  }

  depends_on = [hcloud_network_subnet.nodes]

  lifecycle {
    ignore_changes = [image]
  }
}
