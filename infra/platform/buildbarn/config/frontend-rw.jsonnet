// Read-write frontend. Trusted builds only: post-merge on main, never a pull
// request. Reachable from the runner namespace only by not being in its egress
// allow-list.
(import 'frontend.libsonnet')({ allow: {} })
