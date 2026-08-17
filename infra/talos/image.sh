#!/usr/bin/env bash
# Builds -- or finds -- the Hetzner snapshot this cluster's nodes boot from.
#
# Usage (from //infra/talos:image):
#   image.sh <hcloud-rlocationpath> <hcloud-upload-image-rlocationpath> <talos-version>
#
# Prints the snapshot ID on stdout and nothing else there, so it can be fed
# straight into tofu:
#
#   bazel run //infra/talos:image
#
# Needs HCLOUD_TOKEN. Uploading works by booting a throwaway rescue server and
# writing the image to its disk, so it takes a few minutes and it costs a few
# cents -- which is why this reuses an existing snapshot rather than making a
# new one on every run.

# --- begin runfiles.bash initialization v3 ---
set -uo pipefail
set +e
f=bazel_tools/tools/bash/runfiles/runfiles.bash
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null ||
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null ||
  source "$0.runfiles/$f" 2>/dev/null ||
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null ||
  {
    echo >&2 "ERROR: cannot find $f"
    exit 1
  }
f=
set -e
# --- end runfiles.bash initialization v3 ---

set -euo pipefail

hcloud="$(rlocation "$1")"
upload="$(rlocation "$2")"
talos_version="$3"
location="$4"
server_type="$5"

if [[ -z "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
  echo >&2 "ERROR: use 'bazel run', not 'bazel build' -- this reads schematic.yaml from the source tree."
  exit 1
fi

if [[ -z "${HCLOUD_TOKEN:-}" ]]; then
  echo >&2 "ERROR: HCLOUD_TOKEN is not set. See infra/doc/bootstrap.md."
  exit 1
fi

schematic="${BUILD_WORKSPACE_DIRECTORY}/infra/talos/schematic.yaml"

# Ask the Image Factory to name our schematic rather than hardcoding the answer.
# Factory content-addresses schematics, so this round trip is what guarantees
# the ID cannot drift from the committed file -- and the same ID has to appear
# in machine.install.image, where a stale copy would install a different image
# than the one that booted.
echo >&2 "Resolving schematic ID from ${schematic#"$BUILD_WORKSPACE_DIRECTORY"/} ..."
response="$(curl -sS --fail -X POST --data-binary "@${schematic}" https://factory.talos.dev/schematics)"
schematic_id="$(sed -n 's/.*"id":"\([0-9a-f]*\)".*/\1/p' <<<"$response")"

if [[ ! "$schematic_id" =~ ^[0-9a-f]{64}$ ]]; then
  echo >&2 "ERROR: factory did not return a schematic ID. Response: $response"
  exit 1
fi
echo >&2 "Schematic: $schematic_id"

# The same ID has to appear in machine.install.image, because a node that boots
# one image and installs another works until it reboots -- and that is the worst
# moment to discover it. There is no way to derive it there (a Talos patch is
# data, not a program), so it is written down, and this is what keeps the copy
# honest.
patch="${BUILD_WORKSPACE_DIRECTORY}/infra/talos/patches/hetzner.yaml"
if ! grep -q "installer/${schematic_id}:" "$patch"; then
  echo >&2
  echo >&2 "ERROR: patches/hetzner.yaml does not install this schematic."
  echo >&2 "  schematic.yaml resolves to: $schematic_id"
  echo >&2 "  hetzner.yaml installs:      $(sed -n 's|.*installer/\([0-9a-f]*\):.*|\1|p' "$patch" | head -1)"
  echo >&2
  echo >&2 "Update machine.install.image in that file to match, then run this again."
  exit 1
fi

# Hetzner caps label values at 63 characters and a schematic ID is 64, so the
# label carries a prefix. Thirty-two hex characters is not a collision anyone
# will meet; the full ID is in the description.
label_id="${schematic_id:0:32}"
selector="talos.schematic==${label_id},talos.version==${talos_version}"

existing="$("$hcloud" image list --type snapshot --selector "$selector" -o noheader -o columns=id || true)"
existing="$(tr -d '[:space:]' <<<"$existing")"

if [[ -n "$existing" ]]; then
  echo >&2 "Reusing existing snapshot for this schematic and version."
  echo "$existing"
  exit 0
fi

echo >&2 "No snapshot for this schematic yet; building one on ${server_type} in ${location} (several minutes) ..."

# Location and server type are both stated rather than defaulted. The uploader
# would otherwise pick fsn1 and cax11, invisibly, and report the consequence as
# "unsupported location for server type" -- an error naming neither the type it
# chose nor the reason, since Hetzner says "unsupported" when a type is merely
# out of stock in that datacenter.
#
# --server-type replaces --architecture, which the two are mutually exclusive
# over. The architecture is implied by the type, and cax11 is exactly the
# instance most likely to be exhausted.
"$upload" upload \
  --image-url "https://factory.talos.dev/image/${schematic_id}/${talos_version}/hcloud-amd64.raw.xz" \
  --server-type "$server_type" \
  --compression xz \
  --location "$location" \
  --description "talos ${talos_version} ${schematic_id}" \
  --labels "talos.schematic=${label_id},talos.version=${talos_version}" >&2

# The uploader does not print the ID in a form worth parsing, so ask again by
# the labels we just set. This also proves the labels landed, which is what
# every later run depends on to avoid rebuilding.
"$hcloud" image list --type snapshot --selector "$selector" -o noheader -o columns=id
