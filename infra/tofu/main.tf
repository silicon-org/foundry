# Root module for cluster provisioning.
#
# Empty for now, deliberately: this exists so the hermetic wrapper pattern
# (`bazel run //infra/tofu:plan`) is proven before it has to be trusted with
# real resources.

terraform {
  required_version = "~> 1.12"
}
