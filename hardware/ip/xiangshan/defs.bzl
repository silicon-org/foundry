"""Running XiangShan's Chisel generator as a build action."""

# The generator writes its output files into --target-dir, so the action puts
# that directory where the declared outputs live and the files land in place with
# no copying. What the wrapper adds is a check that the generator emitted exactly
# the files `outs` names.
#
# That check is the point of naming them at all. Bazel cannot know what a
# generator will produce, and the alternatives are both bad: declare a directory,
# and the RTL becomes an opaque tree artifact that no Verilog rule can take
# individual files out of; declare nothing, and blackbox bodies that elaboration
# quietly emitted -- the ones that decide whether a design has SRAMs in it --
# disappear between the action and the simulator. Naming them means the build
# fails when the set changes, which is when someone should look.
#
# Both tools are turned into absolute paths, because the generator hands them to
# subprocesses and $PWD is the only thing all three agree on. espresso goes on
# PATH rather than being passed as an option: Chisel's decoder looks it up by
# name, so there is nowhere else to put it.
_COMMAND = """
set -eu
outdir="$1"; shift
firtool="$PWD/$1"; shift
espresso="$PWD/$1"; shift
expected="$1"; shift

export PATH="$(dirname "$espresso"):$PATH"

mkdir -p "$outdir"
"$@" --target-dir "$outdir" --firtool-binary-path "$firtool"

unexpected=""
for path in "$outdir"/*; do
  file="$(basename "$path")"
  case " $expected " in
    *" $file "*) ;;
    *) unexpected="$unexpected $file" ;;
  esac
done
if [ -n "$unexpected" ]; then
  echo "xiangshan_verilog: generated files that no target declares:$unexpected" >&2
  echo "Add them to outs, or decide deliberately to drop them." >&2
  exit 1
fi
"""

def _xiangshan_verilog_impl(ctx):
    outs = [
        ctx.actions.declare_file("{}/{}".format(ctx.label.name, out))
        for out in ctx.attr.outs
    ]

    args = ctx.actions.args()
    args.add(outs[0].dirname)
    args.add(ctx.file._firtool)
    args.add(ctx.executable._espresso)
    args.add(" ".join(ctx.attr.outs))
    args.add(ctx.executable._generator)

    # Upstream's arguments, split between the two halves they belong to: the
    # Chisel elaboration and the firtool invocation behind it.
    args.add("--config", ctx.attr.config)
    args.add("--num-cores", ctx.attr.num_cores)
    args.add("--issue", ctx.attr.chi_issue)

    # No difftest, no ChiselDB, no DPI calls: this is RTL meant to be integrated
    # and eventually synthesised, not XiangShan's own simulation harness. The
    # reset generator is upstream's release setting and inserts the reset
    # synchronisers a real chip needs.
    args.add("--fpga-platform")
    args.add("--reset-gen")

    args.add("--target", "systemverilog")
    args.add_all(ctx.attr.firtool_opts, before_each = "--firtool-opt")

    # The generator also drops a build/ directory of elaboration reports into
    # whatever directory it is run from, which nothing reads and the sandbox
    # discards.
    ctx.actions.run_shell(
        arguments = [args],
        command = _COMMAND,
        # Fixed values, not the caller's environment.
        # --incompatible_strict_action_env leaves an action's environment empty,
        # and both of these are read unguarded during elaboration -- an unset one
        # is a NoSuchElementException from inside Scala's sys.env, not a message
        # about a missing variable.
        #
        # PATH: two directories that exist on every Unix, enough to satisfy the
        # read without letting the host in. NOOP_HOME: where difftest would write
        # its generated C++, which is the execroot, and which nothing collects
        # because difftest is switched off.
        env = {
            "NOOP_HOME": ".",
            "PATH": "/usr/bin:/bin",
        },
        inputs = [],
        mnemonic = "XiangShanVerilog",
        outputs = outs,
        progress_message = "Generating XiangShan RTL for %s" % ctx.attr.config,
        tools = [
            ctx.attr._generator[DefaultInfo].files_to_run,
            ctx.attr._espresso[DefaultInfo].files_to_run,
            ctx.file._firtool,
        ],
    )

    return [DefaultInfo(files = depset(outs))]

xiangshan_verilog = rule(
    implementation = _xiangshan_verilog_impl,
    doc = """Elaborates a XiangShan configuration into SystemVerilog.

    The result is a normal set of source files, so it can be handed to
    verilog_library and simulated or linted like anything written by hand.
    """,
    attrs = {
        "chi_issue": attr.string(
            default = "E.b",
            doc = "CHI specification issue the L2's outward port speaks.",
        ),
        "config": attr.string(
            doc = "Configuration class in upstream's `top` package, e.g. XSNoCTopConfig.",
            mandatory = True,
        ),
        "firtool_opts": attr.string_list(
            doc = "Passed through to firtool, one --firtool-opt each.",
        ),
        "num_cores": attr.string(
            default = "1",
            doc = "Harts inside the generated top.",
        ),
        "outs": attr.string_list(
            doc = "Every file the generator is expected to produce.",
            mandatory = True,
        ),
        "_espresso": attr.label(
            cfg = "exec",
            default = "//tools/espresso:espresso",
            executable = True,
        ),
        "_firtool": attr.label(
            allow_single_file = True,
            cfg = "exec",
            default = "//tools/firtool:firtool",
        ),
        "_generator": attr.label(
            cfg = "exec",
            default = "@xiangshan//:generator",
            executable = True,
        ),
    },
)
