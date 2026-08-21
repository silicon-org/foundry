# CHIron, vendored

`include/` is a verbatim subset of [CHIron](https://github.com/RISMicroDevices/CHIron),
Apache-2.0, at

```
commit 1581e2374500bb9304e5b3e2bace00b56ea8a8a0   (2026-08-18)
```

`LICENSE` is upstream's. `refresh.sh` re-copies the same file list from another
commit and re-applies `patches/`, so a version bump is a reviewable diff.

One patch is applied, `patches/0001-fix-flit-appender.patch`. It fixes
`Flits::Serialize*`, which has never worked upstream — three defects in one
eight-line function, which the function's own assertion catches on the first
flit. Only deserialization was ever exercised. `git diff` against a fresh
checkout of the commit above is exactly that patch and nothing else.

## Why this is vendored, when nothing else here is

`hardware/README.md` says third-party sources are fetched by `http_archive` and
never copied into this history, and gives the reason: upstream stays at a
version anyone can verify. Three things make CHIron the exception.

It is a *subset*. The repository is 13 MB; what a CHI agent needs is 700 KB in
17 headers. The rest is a Qt trace-viewer GUI (5.0 MB), its tests (2.8 MB), a
second and different protocol under `cchi/` (604 KB), and the Issue-B and
Issue-C variants we do not speak. An `http_archive` would carry all of it
through the CAS on every fetch to reach a twentieth of it.

We may need to patch it. The one part of CHIron this repository would most like
to use — a working HN-F — does not exist upstream: `chi/icn/lunatic/chi_icn_hnf.hpp`
declares the class with an empty body. The pull request that fills it in is
open, unmerged, and machine-authored.

And the subset is header-only and inert. There is no build system to reproduce,
no configure step, no generated code — 17 headers that a `cc_library` names.
Verifying that this directory matches upstream is `refresh.sh` and `git diff`.

## What is here, and what was left out

| Taken | |
|---|---|
| `chi/spec/chi_protocol_flits.hpp` | the four flit layouts as compile-time field tables |
| `chi/spec/chi_protocol_encoding.hpp` | opcodes and field encodings |
| `chi/util/chi_util_flit.hpp` | `Serialize*` / `Deserialize*` against a `uint32_t*` bit array |
| `chi/util/chi_util_decoding.hpp` | human-readable decode |
| `chi/basic/` | the parameter constraints and the connection-level templates |
| `chi_eb/` | the Issue-E.b wrappers: open `namespace CHI::Eb`, define `CHI_ISSUE_EB_ENABLE`, textually include the above |
| `common/nonstdint.hpp`, `utility.hpp` | the wide-integer and helper types those depend on |

Left out: `app/`, `test/`, `cchi/`, `chi/expresso/`, `chi/icn/`, `chi_b/`,
`chi_c/`, `chi/xact/`, `clog/`. The last two are wanted later — `chi/xact/` is
the transaction-level protocol checker and `clog/` the flit trace format — and
will arrive as a second tranche when there is something to check.

## The include mechanism, because it is unusual

CHIron's headers deliberately have `#pragma once` commented out. A header under
`chi/` is included more than once, from different `chi_<issue>/` wrappers, each
of which defines a different `CHI_ISSUE_*_ENABLE` before including it and opens
a different namespace. That is how one source tree describes three issues of the
specification at once.

The consequence for us: include `chi_eb/...`, never `chi/...` directly, and
everything lands in `CHI::Eb::`. `//hardware/vip/chi:chiron` exports only the
`chi_eb/` entry points for that reason.
