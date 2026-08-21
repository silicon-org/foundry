# CHI

AMBA CHI, Issue E.b: field widths, encodings, opcodes, and the typedefs that
turn them into a port list.

```
src/chi_pkg.sv           widths, enums, encodings, classifiers, reference typedefs
include/chi_typedef.svh  the typedef macros a link with different widths uses
```

Issue E.b because that is what `//hardware/soc/xs_cluster` speaks. The current
specification is Issue H; the encodings the two share have not moved, but the
flit *layout* has — Issue H puts `MultiReq`/`NumReq` where E.b has a three-bit
`Size`, replaces `NS` with `PAS[2:0]`, and adds four more optional buses. None
of that is here.

## Why the file is split in two

`chi_typedef.svh` describes a flit and a link; `chi_pkg.sv` describes what the
fields in them mean. They are separate because the widths of a CHI link are a
per-link choice — node ID from 7 to 16 bits, address from 44 to 52, data 128,
256 or 512 — while the encodings are not. Macros taking types as arguments let
a second link with different widths reuse every enum in the package without
redefining one of them.

The common case does not need the macros. `chi_pkg` ends by invoking them at
the configuration declared at its top, which is XiangShan's, and exports
`chi_req_t`, `chi_rsp_t`, `chi_dat_t`, `chi_snp_t`, `chi_rn_link_tx_t` and
`chi_rn_link_rx_t`.

## Flits and links

A flit is a message. A link is six channels of them plus the flow control that
moves them, and CHI's flow control is **not** valid/ready: a transmitter may
send only while it holds an L-Credit, the receiver grants credits by pulsing
`LCRDV`, and there is no `ready` anywhere. `chi_rn_link_tx_t` and
`chi_rn_link_rx_t` group, per direction, the flits that direction sends and the
credits it returns for the flits it receives — so a port pair replaces thirty
loose signals, and the interface has a name.

They are named from the Request Node's point of view. A Home Node uses the same
two types the other way round.

## What checks this

```
bazel test //hardware/ip/chi/test/...
```

Two tests, and between them they mean no encoding in this package is a
transcription nobody verified.

`chi_pkg_test` walks every value of each of the four opcode spaces — 128, 32,
32 and 16 — and compares this package's enum against CHIron's independent
Issue-E.b tables, by name. An opcode defined here and not there, or there and
not here, or at a different value, fails. It also checks `$bits` of every
typedef against the parameters it was built from, and the classifier functions
exhaustively.

`chi_layout_test` drives each channel struct with a distinct pattern per field
and has C++ decode the packed vector with CHIron, then does the reverse. The
package and the agents each know how to read a flit, for good reasons — one for
waveforms, RTL and assertions, the other for the C++ model — and this is what
stops the two drifting apart.
