# These are deterministic -- every address is assigned in servers.tf rather than
# handed out by Hetzner -- so they duplicate what the configuration already
# says. They exist anyway, because "what did this actually create" should be
# answerable without reading HCL and doing arithmetic on cidrhost().
#
# talconfig.yaml carries the same values as literals. If these two ever
# disagree, this is the one telling the truth.

output "control_plane_public_ipv4" {
  description = "Used to apply the first configuration, while a node is in maintenance mode and has no tailnet yet."
  value       = [for ip in hcloud_primary_ip.control_plane : ip.ip_address]
}

output "control_plane_private_ipv4" {
  description = "What the cluster itself uses: etcd, the API server, kubelet."
  value       = [for s in hcloud_server.control_plane : one(s.network).ip]
}

output "worker_public_ipv4" {
  value = [for ip in hcloud_primary_ip.worker : ip.ip_address]
}

output "worker_private_ipv4" {
  value = [for s in hcloud_server.worker : one(s.network).ip]
}

output "apiserver_endpoint" {
  description = "Stable Kubernetes API address. Private, so it resolves over the tailnet and nowhere else."
  value       = "https://${hcloud_load_balancer_network.apiserver.ip}:6443"
}

output "advertise_routes" {
  description = "What the Talos Tailscale extension advertises, making the private network reachable from the tailnet."
  value       = var.network_cidr
}
