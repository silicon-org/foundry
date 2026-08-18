"""The Bazel form of the CMake macros CIRCT declares its dialects with.

CIRCT's dialects are regular in a way that its CMake makes explicit: nearly
every one is an `add_circt_dialect(<Name> <namespace>)`, which expands through
MLIR's `add_mlir_dialect` into the same six tablegen invocations on the same six
output names. Transcribing that eleven times by hand would be eleven chances to
get one of the sixty-six wrong, and would hide the fact that they are all the
same thing.

These live here rather than inside the overlay because a .bzl file cannot be
shipped by an http_archive's `build_file`, which places exactly one file. The
overlay loads them back out of this repository by label, which works because
@circt is declared by this module and so resolves against this module's repo
mapping. Keeping them here has a second benefit: the macros are reviewed next to
everything else, rather than inside a generated-looking file about a third-party
tree.
"""

load("@llvm-project//mlir:tblgen.bzl", "gentbl_cc_library")

_MLIR_TBLGEN = "@llvm-project//mlir:mlir-tblgen"

def circt_dialect(name, namespace, dir = None, deps = [":CIRCTTdFiles"], **kwargs):
    """One dialect's operations, types and dialect registration.

    The Bazel equivalent of `add_circt_dialect(name namespace)`. See
    mlir/cmake/modules/AddMLIR.cmake for the expansion being mirrored; the
    output names are load-bearing, because the dialect's C++ sources include
    them by exactly these paths.

    Args:
      name: the dialect's CamelCase name, e.g. "HW". Also names the .td file.
      namespace: the dialect's assembly namespace, e.g. "hw".
      dir: directory under include/circt/Dialect, when it is not the dialect's
        own name. CHIRRTL is the case that needs it: it is FIRRTL's
        pre-inference form and lives in FIRRTL's directory, because it is not a
        dialect anyone registers on its own.
      deps: TableGen dependencies -- not C++ ones. See the note in
        circt.BUILD.bazel about why there is only ever one of these.
      **kwargs: forwarded to gentbl_cc_library, which forwards to four rules
        including a filegroup, so only universally accepted attributes work.
    """
    stem = "include/circt/Dialect/{dir}/{d}".format(dir = dir or name, d = name)
    gentbl_cc_library(
        name = name + "IncGen",
        tbl_outs = {
            stem + ".h.inc": ["-gen-op-decls"],
            stem + ".cpp.inc": ["-gen-op-defs"],
            stem + "Types.h.inc": ["-gen-typedef-decls", "-typedefs-dialect=" + namespace],
            stem + "Types.cpp.inc": ["-gen-typedef-defs", "-typedefs-dialect=" + namespace],
            stem + "Dialect.h.inc": ["-gen-dialect-decls", "-dialect=" + namespace],
            stem + "Dialect.cpp.inc": ["-gen-dialect-defs", "-dialect=" + namespace],
        },
        tblgen = _MLIR_TBLGEN,
        td_file = stem + ".td",
        deps = deps,
        **kwargs
    )

def circt_interface(name, dir, deps = [":CIRCTTdFiles"], **kwargs):
    """An operation interface declared in its own .td file.

    The Bazel equivalent of `add_circt_interface(name)`, which is MLIR's
    `add_mlir_interface`. Separate from circt_dialect because a dialect may
    declare several or none -- and because not every interface belongs to a
    dialect: InstanceGraphInterface sits under Support, where the CMakeLists is
    a single `add_mlir_interface` line.

    Args:
      name: the interface's name, which is also its .td file's basename.
      dir: directory under include/circt, e.g. "Dialect/HW" or "Support".
      deps: TableGen dependencies.
      **kwargs: forwarded to gentbl_cc_library.
    """
    stem = "include/circt/{dir}/{n}".format(dir = dir, n = name)
    gentbl_cc_library(
        name = name + "IncGen",
        tbl_outs = {
            stem + ".h.inc": ["-gen-op-interface-decls"],
            stem + ".cpp.inc": ["-gen-op-interface-defs"],
        },
        tblgen = _MLIR_TBLGEN,
        td_file = stem + ".td",
        deps = deps,
        **kwargs
    )

def circt_tablegen(name, dialect, td, outs, deps = [":CIRCTTdFiles"], **kwargs):
    """Any other tablegen group: enums, attributes, passes, rewriters.

    A thin spelling of gentbl_cc_library that fills in the tool, the include
    path convention and the single TableGen dependency, so that the call sites
    below read as a list of what is generated rather than of how.

    Args:
      name: target name, conventionally <something>IncGen.
      dialect: the dialect directory under include/circt/Dialect.
      td: the .td file's basename, without extension.
      outs: {output basename: [tblgen options]}, relative to the dialect dir.
      deps: TableGen dependencies.
      **kwargs: forwarded to gentbl_cc_library.
    """
    d = "include/circt/Dialect/" + dialect
    gentbl_cc_library(
        name = name,
        tbl_outs = {d + "/" + out: opts for out, opts in outs.items()},
        tblgen = _MLIR_TBLGEN,
        td_file = d + "/" + td + ".td",
        deps = deps,
        **kwargs
    )
