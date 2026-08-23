"""Generating a mesh as part of the build.

A topology is a description, and the SystemVerilog for it is a build output --
the same argument //hardware/README.md makes about XiangShan's RTL. Checking the
generated files in would mean reviewing a diff nobody wrote and trusting that it
came from the description it claims to.
"""

load("@rules_verilog//verilog:defs.bzl", "verilog_library")

_GENERATOR = "//hardware/ip/chi_noc/nocgen"

def nocgen_topology(name, config, deps = [], visibility = None):
    """A CHI mesh, generated from a topology description.

    Produces three things from one `nocgen` invocation:

      `<name>`           a verilog_library of the netlist and its package
      `<name>_manifest`  the JSON, for whatever drives the mesh in simulation
      `<name>_sources`   the generated files, for reading and for lint

    Args:
        name: target name, and the prefix of every generated file.
        config: the topology YAML.
        deps: verilog_library dependencies the generated RTL needs -- the
            crosspoint and its package. A parameter rather than a constant so
            that a topology can be generated and inspected before
            //hardware/ip/chi_noc has RTL in it to depend on.
        visibility: as usual.
    """
    netlist = name + "_noc.sv"
    package = name + "_noc_pkg.sv"
    manifest = name + "_noc.json"

    native.genrule(
        name = name + "_generate",
        srcs = [config],
        outs = [netlist, package, manifest],
        cmd = " ".join([
            "$(execpath {})".format(_GENERATOR),
            "--config $(execpath {})".format(config),
            "--out $(RULEDIR)",
            "--name {}".format(name),
            "> /dev/null",
        ]),
        tools = [_GENERATOR],
        visibility = visibility,
    )

    native.filegroup(
        name = name + "_sources",
        srcs = [netlist, package],
        visibility = visibility,
    )

    native.filegroup(
        name = name + "_manifest",
        srcs = [manifest],
        visibility = visibility,
    )

    # The package has to come first: the netlist imports it, and rules_verilog
    # passes srcs to the simulator in order.
    #
    # `top_module` is what puts a generated mesh under the lint aspect
    # (`bazel build --config=lint //hardware/...`). That elaborates the whole
    # netlist against the real crosspoint, which is the check that the generator
    # and the RTL still agree about the port list -- the one kind of drift a
    # golden-file test cannot see, because both sides of it are generated.
    verilog_library(
        name = name,
        srcs = [package, netlist],
        top_module = name + "_noc",
        deps = deps,
        visibility = visibility,
    )
