# What the next steps of the bootstrap need. talhelper wants the node addresses
# and the API endpoint; both are easier to read from here than to look up.

output "control_plane_public_ipv4" {
  description = "Public addresses. Used to apply the first configuration, while the node is in maintenance mode and has no tailnet yet."
  value       = [for s in hcloud_server.control_plane : s.ipv4_address]
}

output "control_plane_private_ipv4" {
  description = "Private addresses. What the cluster itself uses, and what talhelper records as node endpoints."
  value       = [for s in hcloud_server.control_plane : one(s.network).ip]
}

output "worker_public_ipv4" {
  value = [for s in hcloud_server.worker : s.ipv4_address]
}

output "worker_private_ipv4" {
  value = [for s in hcloud_server.worker : one(s.network).ip]
}

output "apiserver_endpoint" {
  description = "Stable Kubernetes API address. Private, so it resolves over the tailnet and nowhere else."
  value       = "https://${one(hcloud_load_balancer_network.apiserver.ip[*])}:6443"
}

output "network_cidr" {
  description = "Route the Tailscale extension advertises, so the private network is reachable from the tailnet."
  value       = var.network_cidr
}
