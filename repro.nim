## Reprobuild project file for ngx-isonim.
##
## **Typed-Cross-Project-Deps rollout — a Nim CONSUMER of the isonim
## ecosystem (SC-11 develop-mode from-source sibling consumption).**
## ``ngx-isonim`` is the nginx native SSR module for IsoNim. Its own module
## tree (``src/handler.nim`` + the ``nginx_*`` adapters) is a pure-Nim,
## nginx-C-API leaf when compiled in TEST (mock) mode — ``-d:isNginxTest``
## makes ``src/nginx_types.nim`` / ``src/apps.nim`` swap the real nginx
## bindings + the real IsoNim SSR import for mock implementations, so the
## unit-test corpus needs neither nginx headers nor the isonim sibling. But
## ONE test — ``tests/test_isonim_e2e.nim`` — drives the REAL IsoNim reactive
## core + SSR renderer (via ``tests/e2e/apps/isonim_task_app.nim``, which
## ``import isonim/core/...`` + ``isonim/ssr/...`` + ``isonim/dsl/ui``), so it
## is a genuine cross-repo consumer of the ``isonim`` sibling.
##
## Two landed workspace Nim-library producers are consumed from source at
## build time by that test:
##
##   * ``isonim`` — the isomorphic reactive UI framework
##     (``isonim/core/{owner,signals,computation}`` +
##     ``isonim/ssr/{renderer,markers,escape}`` + ``isonim/dsl/ui``).
##     Producer: ``isonim/repro.nim`` → ``library isonim`` (exported path
##     ``src``). Consumers ``import isonim/...`` submodules.
##   * ``nim-everywhere`` — the cross-target platform seams isonim's SSR /
##     reactive core pull in transitively (async / time / http facade).
##     Producer: ``nim-everywhere/repro.nim`` → ``library nim_everywhere``.
##
## The repo's own ``Justfile`` ``test-isonim`` recipe resolves these with
## hand-maintained ``--path:../isonim/src --path:../nim-everywhere/src`` flags
## (and the flake overrides them as ``isonim=path:../isonim`` /
## ``nim-everywhere=path:../nim-everywhere`` sibling inputs). This recipe
## expresses those two sibling dependencies the reprobuild-native way
## instead: ``uses: "<sibling>"`` names each PRODUCER project by its workspace
## directory name; reprobuild builds each from source (its ``library`` edge)
## and threads its ``src/`` root onto the consumer test's ``nim c --path:``
## via the SC-11 ``nimPathDirs`` aux channel
## (Cross-Repo-Source-Consumption.md §4.2a) — replacing the hardcoded
## ``../isonim/src`` / ``../nim-everywhere/src`` literals. Editing a sibling's
## ``src/`` invalidates + rebuilds this repo's affected test compile.
##
## Both siblings are in the rollout's AVAILABLE set (each ships a landed
## ``repro.nim`` with a ``library`` export), so this is proper SC-11
## develop-mode consumption — NOT a SKIP and NOT a hardcoded path.
##
## **Third-party deps (NOT ``uses:``).** The consumer test also puts two
## status-im workspace source trees on ``--path`` — ``../nim-faststreams``
## (the nimble file's ``requires "faststreams >= 0.3.0"``) and ``../nim-stew``
## — exactly as ``Justfile`` ``test-isonim`` does. These are THIRD-PARTY
## upstreams EXCLUDED from the rollout (no ``repro.nim`` ``library`` export),
## so they are NOT ``uses:`` sibling-from-source edges: they are threaded via
## the edge ``paths:`` slot the way the repo's own build treats them. If/when
## they land a ``repro.nim`` with a ``library`` export they can be promoted to
## ``uses:`` edges.
##
## A Mode 1 / Mode 3 hybrid (per
## ``reprobuild-specs/Three-Mode-Convention-System.md``) modelled on the
## canonical Nim-consumer recipe ``isonim/repro.nim`` (its own SC-11 sibling
## consumer) and the leaf ``nim-pty/repro.nim`` / ``nim-libvterm/repro.nim``:
##
## * Declares the toolchain floor via ``uses:`` (``nim`` + ``gcc``) plus the
##   two sibling ``uses:`` edges. Mirrors the nimble file's
##   ``requires "nim >= 2.0.0"``.
## * Declares ``library ngx_isonim`` — the importable ``src/`` tree (so any
##   downstream repo could consume this module's adapters via
##   ``uses: "ngx-isonim"``). The exported path is ``src`` (convention
##   default).
## * Emits, per HEADLESS-runnable test file under ``tests/``, a BUILD edge
##   (``buildNimUnittest.build``) that compiles ``build/test-bin/<stem>`` and
##   an EXECUTE edge (``edge.testBinary.run``) — the two-edge test template
##   from ``reprobuild-specs/Package-Model.md`` §"The test template". BUILD
##   halves collect into ``test-builds``; EXECUTE halves into ``test`` so
##   ``repro build test`` / ``repro test`` materialise the runnable closure
##   (each execute edge transitively depends on its build edge).
##
## **Two compile-mode groups.** The corpus splits by the ``-d:`` mode the
## repo's own ``Justfile`` compiles each test under (the engine build does not
## read ``config.nims``/``nim.cfg``, so every ``-d:`` is passed explicitly):
##
##   * **Mock/unit group** (``Justfile`` ``test`` + ``test-e2e-integration``)
##     — ``-d:isNginxTest``. Under this define ``src/nginx_types.nim`` swaps to
##     the MOCK nginx bindings (no real nginx headers) and ``src/apps.nim``
##     compiles to nothing (its real ``import isonim/...`` block is
##     ``when not defined(isNginxTest)``), so these tests are a pure-Nim LEAF —
##     they need neither the nginx dev headers nor the isonim sibling. Six
##     files:
##       - ``test_adapter``            (``import ../src/nginx_adapter``)
##       - ``test_handler``            (``import ../src/handler`` + e2e/apps/hello)
##       - ``test_config``             (``import ../src/config``)
##       - ``test_streaming_handler``  (``import ../src/{handler,nginx_adapter}``)
##       - ``test_e2e_integration``    (``import ../src/handler`` + 4 e2e apps)
##       - ``test_nginx_headers``      (``import ../src/nginx_http_adapter``)
##     ``test_nginx_headers`` is not in a ``Justfile`` recipe but is a real
##     ``unittest`` suite that compiles + runs headless under ``-d:isNginxTest``
##     (it exercises the mock header-list adapter), so it gets a full edge.
##
##   * **IsoNim-SSR group** (``Justfile`` ``test-isonim``) —
##     ``-d:isServer -d:asyncBackend=none`` + the sibling ``src`` roots. ONE
##     file:
##       - ``test_isonim_e2e`` — drives the REAL isonim reactive core + SSR
##         renderer (``import e2e/apps/isonim_task_app`` → ``import
##         isonim/...``). This is the SC-11 sibling-exercising test: its
##         compile threads ``isonim/src`` + ``nim-everywhere/src`` via the
##         ``uses:`` ``nimPathDirs`` channel, plus ``../nim-faststreams`` +
##         ``../nim-stew`` via ``paths:``. FULL build+execute (headless).
##
## **Per-test platform gating.** Every test file is host-portable: none has
## an OS ``when defined(windows|macos|linux)`` extraction gate, and none is
## host-exclusive. All eight tests compile + run to exit 0 under ``nim c`` on
## this Linux host — verified by a direct ``nim c`` sweep with the same paths +
## defines the edges below use. So there are no ``when defined(...)``
## extraction gates for the test set on this host.
##
## **Not modelled.** ``tests/e2e/test_e2e.sh`` + the ``Justfile``
## ``start-*`` / ``bench-*`` recipes drive a LIVE nginx server (build the
## ``.so`` module, start nginx on a port, curl it / run ``wrk``). That is an
## external-service integration path (a running nginx daemon), not a headless
## ``unittest`` binary, so it is out of the sanctioned headless test scope and
## gets no edge — the mock-mode + isonim-SSR ``unittest`` corpus above is the
## complete set of files the repo compiles + runs with ``nim c -r``.
## The ``benchmarks/ssr_profile.nim`` profiler is likewise a benchmark driver,
## not a test, and is not modelled.
##
## **Tool provisioning.** ``defaultToolProvisioning "path"`` matches the
## canonical recipes: the nix dev shell puts ``nim`` + ``gcc`` on ``PATH``,
## so the weak-local PATH resolver is the right default. It is also required
## for the ``uses:`` declarations to resolve at all ("typed tool provisioning
## is required for uses declarations").

import repro_project_dsl

# ``ct_test_nim_unittest`` supplies the ``buildNimUnittest.build(...)``
# typed-tool used by every test BUILD edge and the ``edge.testBinary.run(...)``
# UFCS dispatch for the EXECUTE edges. It re-exports ``repro_project_dsl`` so
# the import order is unimportant. Like the isonim consumer recipe this file
# does NOT import ``ct_test_runner_install`` (engine-coupled,
# reprobuild-internal): the execute edges route through the engine's default
# direct-binary runner (run the binary, key on exit status), which is exactly
# the exit-0 verification this corpus needs — Nim ``unittest`` prints per-suite
# results and exits non-zero on failure.
import ct_test_nim_unittest

type
  NgxTestSpec = object
    ## One entry per HEADLESS-runnable native test file. ``source`` is the
    ## repo-relative ``.nim`` path; ``binary`` is the ``build/test-bin/<stem>``
    ## output.
    source: string
    binary: string

proc spec(stem: string): NgxTestSpec =
  NgxTestSpec(source: "tests/" & stem & ".nim",
    binary: "build/test-bin/" & stem)

# Mock/unit group — ``-d:isNginxTest``. Pure-Nim leaf (mock nginx bindings +
# empty ``apps.nim``); no nginx headers, no isonim sibling.
const mockTestSpecs: seq[NgxTestSpec] = @[
  spec("test_adapter"),
  spec("test_handler"),
  spec("test_config"),
  spec("test_streaming_handler"),
  spec("test_e2e_integration"),
  spec("test_nginx_headers"),
]

# IsoNim-SSR group — ``-d:isServer -d:asyncBackend=none`` + the SC-11 sibling
# ``src`` roots (threaded off the ``uses:`` edges) + the third-party
# faststreams/stew paths. Drives the REAL isonim reactive core + SSR renderer.
const ssrTestSpecs: seq[NgxTestSpec] = @[
  spec("test_isonim_e2e"),
]

package ngx_isonim:
  defaultToolProvisioning "path"

  uses:
    # Toolchain floor — the PATH-resolvable binaries the build needs. ``nim``
    # compiles every test binary (the ``buildNimUnittest.build`` edges below,
    # matching the nimble file's ``requires "nim >= 2.0.0"``); ``gcc`` is the
    # C back-end ``nim c`` shells out to. Sufficient for the path-mode
    # resolver under ``nix develop``.
    "nim >=2.0"
    "gcc >=12"

    # The landed sibling Nim-library producers the IsoNim-SSR test consumes
    # from source (SC-11 develop-mode). Naming the workspace project here
    # makes reprobuild build the sibling from source (its ``library`` edge)
    # and thread its ``src/`` root onto this repo's ``nim c --path:`` via the
    # ``nimPathDirs`` aux channel — replacing the ``Justfile``'s hardcoded
    # ``--path:../isonim/src`` / ``--path:../nim-everywhere/src``.
    "isonim"          # library isonim
    "nim-everywhere"  # library nim_everywhere

  # Library declaration — the ``src/`` tree is importable when this package is
  # consumed via ``uses: "ngx-isonim"``. The exported path is ``src``
  # (convention default).
  library ngx_isonim

  build:
    # Two-edge test template (Package-Model.md §"The test template"): one
    # compile BUILD edge + one EXECUTE edge per test file. BUILD halves
    # collect into ``test-builds`` (compile verification); EXECUTE halves into
    # ``test`` so ``repro test`` / ``repro build test`` materialise the
    # runnable closure (each execute edge transitively depends on its build
    # edge).
    var testBuildActions: seq[BuildActionDef] = @[]
    var testExecuteActions: seq[BuildActionDef] = @[]

    proc emitTest(source, binary: string;
                  defines, paths: seq[string];
                  buildActions, executeActions: var seq[BuildActionDef]) =
      var lastSlash = -1
      for i in 0 ..< binary.len:
        if binary[i] == '/' or binary[i] == '\\':
          lastSlash = i
      let stem =
        if lastSlash >= 0: binary[lastSlash + 1 .. ^1]
        else: binary
      let edge = buildNimUnittest.build(
        source = source,
        binary = binary,
        defines = defines,
        paths = paths,
        mm = "orc",
        actionId = "ngx_isonim.test_build." & stem,
        # ``src`` + the nimble file are declared inputs so the monitor tracks
        # the transitively imported ``src/**`` adapter/handler tree (and, for
        # the SSR test, its e2e app tree).
        extraInputs = @["src", "tests/e2e", "ngx_isonim.nimble"])
      buildActions.add(edge.action)
      # ``registerImplicitName = false``: the BUILD edge already owns the
      # binary basename as the implicit target name; the explicit ``actionId``
      # is the execute edge's selector (two-edge shape).
      let executeEdge = edge.testBinary.run(
        actionId = "ngx_isonim.test_execute." & stem,
        registerImplicitName = false)
      executeActions.add(executeEdge)

    # Mock/unit group — ``-d:isNginxTest``; ``paths = @["src"]`` for the
    # ``import ../src/...`` module tree (relative imports resolve from the test
    # file's own ``tests/`` dir; ``src`` on ``--path`` covers the handful of
    # bare ``import`` sites). Leaf: no sibling / third-party paths.
    for s in mockTestSpecs:
      emitTest(s.source, s.binary,
        defines = @["isNginxTest"],
        paths = @["src"],
        testBuildActions, testExecuteActions)

    # IsoNim-SSR group — ``-d:isServer -d:asyncBackend=none``. The two SC-11
    # sibling ``src`` roots (``isonim/src`` + ``nim-everywhere/src``) are
    # threaded automatically by the ``uses:`` ``nimPathDirs`` channel; here we
    # add only the repo's own ``src`` and the THIRD-PARTY status-im trees
    # (``../nim-faststreams`` + ``../nim-stew``) the ``Justfile`` ``test-isonim``
    # puts on ``--path`` (NOT ``uses:`` — excluded from the rollout).
    for s in ssrTestSpecs:
      emitTest(s.source, s.binary,
        defines = @["isServer", "asyncBackend=none"],
        paths = @["src", "../nim-faststreams", "../nim-stew"],
        testBuildActions, testExecuteActions)

    discard collect("test", testExecuteActions)
    discard collect("test-builds", testBuildActions)
