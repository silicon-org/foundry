"""How upstream's Chisel modules are compiled.

Every module in XiangShan's build.mill extends one `ChiselModule` trait: same
Scala version, same compiler plugin, same flags. This macro is that trait. It
exists so the settings live in one place -- a module compiled with different
flags than upstream compiles it with is a difference nobody would notice until
the RTL came out different.
"""

load("@rules_scala//scala:scala.bzl", "scala_library")

# From build.mill. The compiler plugin is not optional: Chisel uses it to attach
# source locators to hardware, and -Ymacro-annotations is what lets the
# annotation macros in Chisel and rocket-chip expand at all. Upstream also
# passes -deprecation and -feature to its own module; both only affect warnings,
# so they are left out rather than applied unevenly.
_SCALACOPTS = [
    "-language:reflectiveCalls",
    "-Ymacro-annotations",
    "-Ytasty-reader",
]

_PLUGINS = ["@xs_maven//:org_chipsalliance_chisel_plugin_2_13_18"]

# build.mill's ChiselModule.ivyDeps, which every module inherits.
_DEPS = [
    "@xs_maven//:org_chipsalliance_chisel_2_13",
    "@xs_maven//:com_lihaoyi_sourcecode_2_13",
]

def macro_library(name, srcs, **kwargs):
    """A library of compile-time macros, compiled so that its users can expand them.

    Deliberately not `scala_macro_library`. That rule builds an interface jar and
    hands the real one only to targets that depend on it directly, and upstream's
    macros are expanded several modules away -- rocket-chip's `ValName`
    materialises in Utility, in XSCache, in the core. An interface jar has no
    method bodies to expand, so expansion fails with `ClassFormatError: Absent
    Code attribute`, which names the macro and nothing about the target that
    needs it.

    Args:
      name: target name.
      srcs: Scala sources defining the macros.
      **kwargs: passed through to scala_library.
    """
    scala_library(
        name = name,
        srcs = srcs,
        build_ijar = False,
        deps = ["@xs_maven//:org_scala_lang_scala_reflect"],
        **kwargs
    )

def chisel_library(name, srcs, deps = [], **kwargs):
    """A Scala library compiled the way upstream compiles its Chisel modules.

    Args:
      name: target name.
      srcs: Scala sources, usually a glob over the module's src/main/scala.
      deps: other Chisel libraries this one sits on top of.
      **kwargs: passed through to scala_library; `resources` and
        `resource_strip_prefix` are the ones that come up, because elaboration
        reads Verilog blackbox bodies and lookup tables back off the classpath.
    """
    scala_library(
        name = name,
        srcs = srcs,
        # Exported, not just depended on. Diplomacy leaks types across module
        # boundaries constantly -- a bundle from rocket-chip appears in an
        # XSCache signature -- so a strict-deps classpath would be a running
        # battle with someone else's design.
        exports = _DEPS + deps,
        plugins = _PLUGINS,
        scalacopts = _SCALACOPTS,
        deps = _DEPS + deps,
        **kwargs
    )
