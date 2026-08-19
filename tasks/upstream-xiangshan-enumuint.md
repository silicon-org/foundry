# Upstream draft: EnumUInt reflection order makes elaboration irreproducible

Target: [OpenXiangShan/XiangShan](https://github.com/OpenXiangShan/XiangShan)
File: `src/main/scala/utils/EnumUInt.scala`
Observed on: `a7fc87df1e82211eb47f3c74a8c93cd9d425572b` (kunminghu-v3), Chisel 7.13.0,
firtool 1.149.0, JDK 21 (Temurin, aarch64 macOS)

The one-line change is in `hardware/ip/xiangshan/enum_uint_reflection_order.patch`.
This file is the prose to go with it. Suggested as a PR, since the fix is smaller
than the explanation.

---

## Title

`fix(utils): sort EnumUInt members so elaboration is reproducible`

## Body

### Elaborating the same design twice produces different RTL

Generating `XSNoCTopConfig` twice from an unchanged tree, with identical
arguments, produces FIRRTL that differs — and therefore SystemVerilog that
differs. Nine elaborations here produced **six distinct outputs**. Nothing about
the design changes; the emitted wire names do.

```
$ ./generator --config XSNoCTopConfig --num-cores 1 --issue E.b \
      --fpga-platform --reset-gen --target firrtl --dump-fir --target-dir out
$ sha256sum out/XSTop.fir       # differs from run to run
```

The diff is confined to nodes generated from `EnumUInt.assertLegal`:

```
-  node _s2_alignedPdInfoVec_0_brAttribute_T_3 = eq(UInt<2>(0h3), ..._branchType) @[utils/EnumUInt.scala 210:35]
-  node _s2_alignedPdInfoVec_0_brAttribute_T_4 = eq(UInt<2>(0h1), ..._branchType) @[utils/EnumUInt.scala 210:35]
+  node _s2_alignedPdInfoVec_0_brAttribute_T_3 = eq(UInt<2>(0h1), ..._branchType) @[utils/EnumUInt.scala 210:35]
+  node _s2_alignedPdInfoVec_0_brAttribute_T_4 = eq(UInt<2>(0h3), ..._branchType) @[utils/EnumUInt.scala 210:35]
```

Two comparisons against `BranchAttribute.BranchType` swap places. That renames
the nodes around them, and every later stage inherits the new names: in our
build, 216 wire names move in a 139 MB `XSTop.sv`.

### Cause

`validate()` discovers an enum's members by reflection:

```scala
val methodsAll = this.getClass.getDeclaredMethods
  .filter { method =>
    method.getReturnType == classOf[UInt] &&
    method.getParameterTypes.isEmpty
  }
val methods = methodsAll.filter(_.getName()(0).isUpper)
this.names  = methods.map(_.getName).toSeq
this.values = methods.map(_.invoke(this).asInstanceOf[UInt]).toSeq
```

`Class.getDeclaredMethods` is documented as returning members *"not sorted and
... not in any particular order"*, and HotSpot does vary it between runs. The
order is then preserved into `values`, and `assertLegal` generates hardware in
that order:

```scala
VecInit(this.values.map(_ === that)).asUInt.orR
```

So a legality assertion decides the names of the surrounding logic, and the JVM
decides the assertion's shape.

Worth noting what this is *not*: it is not JVM identity-hash iteration order
(pinning it with `-XX:hashCode=2` changes nothing), and it is not firtool or
espresso — both are byte-deterministic on fixed input. Only the reflection order
varies.

### Fix

```diff
-    val methods = methodsAll.filter(_.getName()(0).isUpper) // UpperCamelCase
+    val methods = methodsAll.filter(_.getName()(0).isUpper).sortBy(_.getName) // UpperCamelCase
```

Five elaborations after this change produce one output.

### Why sorting is safe

`values` is never indexed positionally. It is used by:

- `assertLegal`, which reduces it with `orR` — order-independent;
- `getValidSeq`, which pairs each value with its name and whose callers select
  by name;
- `validate`'s own duplicate/width/one-hot checks, which are order-independent
  (a duplicate pair is still detected; only which member is named "first" in the
  message can change).

`getValuesString` already sorts before printing, ten lines above, so the file
itself treats the reflection order as arbitrary.

Sorting by name rather than by value is deliberate: `allowDuplicate` permits two
members to share a `litValue`, so value is not a total order, while method names
within a class are unique.

### Impact if left as is

Any downstream consumer that caches or diffs generated RTL is affected: build
caches miss on unchanged input, and a diff between two revisions carries noise
that hides real changes. It is invisible from inside a single build, which is
probably why it has survived — you only see it by generating twice and
comparing.
