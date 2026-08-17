# Three control planes need one address between them, or every client has to
# know all three and which are alive.
#
# The load balancer has no public interface. That is what keeps invariant #4
# true: Hetzner load balancers cannot have a firewall attached, so a public one
# would put the Kubernetes API on the open internet with nothing in front of it
# -- exactly the thing architecture.md lists as a non-goal.
#
# Reaching a private address from a laptop is then the tailnet's job. The Talos
# Tailscale extension advertises this network as a route (see
# patches/hetzner.yaml), so the load balancer, and cluster Services generally,
# resolve for anyone on the tailnet and for nobody else. Routes need approving
# once in the Tailscale admin console, or automatically via an ACL autoApprover.
resource "hcloud_load_balancer" "apiserver" {
  name               = "foundry-apiserver"
  load_balancer_type = "lb11"
  location           = local.location
}

resource "hcloud_load_balancer_network" "apiserver" {
  load_balancer_id        = hcloud_load_balancer.apiserver.id
  network_id              = hcloud_network.cluster.id
  enable_public_interface = false

  depends_on = [hcloud_network_subnet.nodes]
}

# Selecting targets by label rather than by ID means changing
# control_plane_count does not require touching this file.
resource "hcloud_load_balancer_target" "control_plane" {
  type             = "label_selector"
  load_balancer_id = hcloud_load_balancer.apiserver.id
  label_selector   = "cluster=foundry,role=control-plane"
  use_private_ip   = true

  depends_on = [hcloud_load_balancer_network.apiserver]
}

resource "hcloud_load_balancer_service" "apiserver" {
  load_balancer_id = hcloud_load_balancer.apiserver.id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443

  # TCP rather than HTTP: the API server wants mutual TLS, so a health check
  # that spoke HTTP would be reporting on a handshake it cannot complete.
  health_check {
    protocol = "tcp"
    port     = 6443
    interval = 10
    timeout  = 5
    retries  = 3
  }
}
