#!/usr/bin/env bash
# Re-copy the vendored CHIron subset from an upstream commit.
#
#   ./refresh.sh <commit-sha>
#
# The file list below is the include closure of chi_eb/spec/chi_eb_protocol.hpp
# and chi_eb/util/chi_eb_util_{flit,decoding}.hpp, and nothing else. It was
# derived with `clang++ -H` rather than by reading the includes, because CHIron
# includes headers textually more than once and the graph is not obvious.
#
# Re-derive it after a bump that adds or moves files:
#
#   clang++ -std=c++20 -fsyntax-only -I <checkout> -H probe.cc 2>&1 \
#     | grep -o '<checkout>/[^ ]*'
#
# Then: run this, read `git diff`, and update the commit in PROVENANCE.md.
set -euo pipefail

sha="${1:?usage: refresh.sh <commit-sha>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

files=(
  chi/basic/chi_conn.hpp
  chi/basic/chi_parameters.hpp
  chi/spec/chi_protocol_encoding.hpp
  chi/spec/chi_protocol_encoding_header.hpp
  chi/spec/chi_protocol_flits.hpp
  chi/spec/chi_protocol_flits_header.hpp
  chi/util/chi_util_decoding.hpp
  chi/util/chi_util_decoding_header.hpp
  chi/util/chi_util_flit.hpp
  chi/util/chi_util_flit_header.hpp
  chi_eb/spec/chi_eb_protocol.hpp
  chi_eb/spec/chi_eb_protocol_encoding.hpp
  chi_eb/spec/chi_eb_protocol_flits.hpp
  chi_eb/util/chi_eb_util_decoding.hpp
  chi_eb/util/chi_eb_util_flit.hpp
  common/nonstdint.hpp
  common/utility.hpp
)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A full clone rather than --depth 1, because the argument is a sha and not a
# branch, and a shallow fetch of an arbitrary object needs server-side support
# that is not universal.
git clone --quiet https://github.com/RISMicroDevices/CHIron.git "$tmp/CHIron"
git -C "$tmp/CHIron" checkout --quiet "$sha"

rm -rf "$here/include"
cp "$tmp/CHIron/LICENSE" "$here/LICENSE"
for f in "${files[@]}"; do
  mkdir -p "$here/include/$(dirname "$f")"
  cp "$tmp/CHIron/$f" "$here/include/$f"
done

# Our fixes, applied in order. Each carries its own rationale; see patches/.
# A patch that no longer applies means upstream has touched the same code, and
# the right response is to read what they did rather than to force it through.
shopt -s nullglob
for patch in "$here"/patches/*.patch; do
  echo "Applying $(basename "$patch")"
  patch --quiet --strip=1 --directory="$here" --input="$patch"
done

echo "Copied ${#files[@]} files from CHIron $sha."
echo "Now update the commit in PROVENANCE.md and read the diff."
