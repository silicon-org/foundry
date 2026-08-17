# The private network carries everything Kubernetes does: etcd, the API server,
# kubelet, and pod traffic via Cilium. Tailscale carries administration only.
#
# That split is deliberate and it is enforced on the Talos side too, in
# patches/hetzner.yaml, which pins kubelet's node IP and etcd's advertised
# address into this CIDR. Without that pinning a node can advertise its
# Tailscale address and cluster traffic quietly starts transiting the VPN --
# slower, and dependent on a service that is supposed to be able to fail without
# taking the cluster with it.
resource "hcloud_network" "cluster" {
  name     = "foundry"
  ip_range = var.network_cidr
}

resource "hcloud_network_subnet" "nodes" {
  network_id   = hcloud_network.cluster.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = var.node_subnet
}

# Hetzner cloud firewalls filter the public interface only; private network
# traffic is never subject to them. So this can deny effectively everything
# inbound without any risk of severing the cluster from itself.
resource "hcloud_firewall" "nodes" {
  name = "foundry-nodes"

  # Tailscale's direct path. Without an inbound port, two peers behind no NAT
  # still find each other, but traffic falls back to DERP relays -- which is
  # fine for a shell and poor for a build cache, where the payload is large
  # blobs and the relay becomes the bottleneck.
  #
  # This is not a management port in the sense invariant #4 is about. Nothing
  # listens here that authenticates by network position: it is a WireGuard
  # endpoint, so an unauthenticated packet is discarded by key, not by firewall.
  rule {
    direction   = "in"
    protocol    = "udp"
    port        = "41641"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "Tailscale direct connections"
  }

  # Break-glass, and bootstrap. A node in maintenance mode has no tailnet, so
  # the very first configuration has to arrive some other way; and when the
  # tailnet is down, this is the documented way back in.
  #
  # Normally off. Turning it on is a tofu apply with a reason, which is a better
  # record than a firewall rule nobody remembers adding.
  dynamic "rule" {
    for_each = var.admin_access_enabled ? [1] : []
    content {
      direction   = "in"
      protocol    = "tcp"
      port        = "50000"
      source_ips  = [var.admin_ipv4]
      description = "Talos API, administrative access"
    }
  }

  dynamic "rule" {
    for_each = var.admin_access_enabled ? [1] : []
    content {
      direction   = "in"
      protocol    = "tcp"
      port        = "6443"
      source_ips  = [var.admin_ipv4]
      description = "Kubernetes API, administrative access"
    }
  }

  lifecycle {
    precondition {
      condition     = !var.admin_access_enabled || var.admin_ipv4 != null
      error_message = "admin_access_enabled requires admin_ipv4; opening these ports to everyone is not a fallback."
    }
  }
}
