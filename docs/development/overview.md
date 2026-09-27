# setu — development overview

> setu (सेतु — *bridge*) is the AGNOS **native display-protocol contract
> lib** — the wire between the `dhancha` client and the `aethersafha`
> compositor. It carries **only** pixel / input / surface-lifecycle message
> **types** plus a pure wire **codec**. It is **agent-free by design**.

## Why setu exists

The sovereign desktop narrows to one seam: the (complete) dhancha client ↔
the (running) aethersafha compositor. The founding architectural decision
(see the design proposal,
`agnosticos/docs/development/planning/native-display-protocol.md`) is **two
planes, not one**:

- **DISPLAY plane — `setu`** (this repo): pixels, input, surface lifecycle.
  **Zero agent-awareness.** This is what keeps the desktop AI-optional by
  construction.
- **AGENT plane** — aethersafha as a `bote` MCP host (a *separate*
  endpoint, gated by `t-ron`, driven by `daimon`). Surfaces exposed as MCP
  resources, drive-verbs as MCP tools. This shares **no wire and no message
  type** with setu.

Putting the agent story anywhere near the display wire would couple "the OS
stands on its own with zero AI" to an agent runtime. The split makes that
impossible by construction: a plain GUI app speaks only setu.

## What's in the lib

The contract (types + a pure codec) plus the one transport every consumer
shares, so the wire and its framing each have a single definition.

| Module | Role |
|---|---|
| `src/error.cyr` | `SetuErr` — the shared error vocabulary (`SETU_OK` / `_ERR_OOM` / `_ERR_BADMSG` / `_ERR_SHORT` / `_ERR_UNSUPPORTED` / `_ERR_OTHER`). |
| `src/proto.cyr` | `SetuMsgKind`, the `SetuMsg` record `{ kind, argc, args[8] }`, per-kind constructors, the expected-argc table, validation. |
| `src/codec.cyr` | `setu_encode` / `setu_decode` / `setu_encoded_len` + the LE i64 byte marshalling. Pure, allocation-light, bounds-checked. |
| `src/buf.cyr` | The shared-buffer present path: pixels travel out-of-band, keyed by an integer id (agnos kernel shm; a `/dev/shm` file on Linux). |
| `src/client.cyr` | The reference transport every client uses: the `#97` channel band on agnos (the compositor endows the channel at spawn), AF_UNIX `SOCK_SEQPACKET` on Linux, where it also provides the listen / accept side. |

### Module order

`[lib].modules` in `cyrius.cyml` (what `cyrius distlib` concatenates into
`dist/setu.cyr`, includes stripped) and the include list in `src/lib.cyr`
share one dependency order: `error` (no deps) → `proto` → `codec` (uses
both) → `buf` (stdlib only) → `client` (uses `proto`, `codec` and `buf`).
Stdlib includes live only in `src/lib.cyr`, which is what keeps the
concatenated bundle compile-clean. Reorder or add a module in both places
together, then re-run `cyrius distlib` and confirm the bundle still
compiles.

### The wire

```
  [ kind ][ argc ][ arg0 ] ... [ arg(argc-1) ]    little-endian i64 words
```

`(2 + argc) * 8` bytes. `argc` is validated against the per-kind table
**before** it sizes any read, so a forged frame cannot drive an
out-of-bounds arg loop. `setu_decode` treats input as **untrusted** — every
read is bounds-checked; short / bad-argc / unknown-kind frames return a
negated `SetuErr`, never a partial message.

### Message ABI (frozen for 0.x)

| Kind (value) | Dir | Args |
|---|---|---|
| `SETU_HELLO` (1) | C↔S | version, role |
| `SETU_CREATE_SURFACE` (2) | C→S | w, h, flags |
| `SETU_SURFACE_CREATED` (3) | S→C | id |
| `SETU_CONFIGURE` (4) | S→C | id, w, h, state |
| `SETU_ATTACH` (5) | C→S | id, w, h, stride, fmt |
| `SETU_COMMIT` (6) | C→S | id |
| `SETU_CLOSE` (7) | C↔S | id |
| `SETU_INPUT_KEY` (8) | S→C | id, keysym, mods |
| `SETU_INPUT_PTR_MOVE` (9) | S→C | id, x, y |
| `SETU_INPUT_PTR_BTN` (10) | S→C | id, button, state |
| `SETU_INPUT_FOCUS` (11) | S→C | id, focused |

**`SETU_ATTACH` fd is out-of-band.** The memfd/shm fd backing the pixel
buffer is passed via `SCM_RIGHTS` over the transport socket — *not* in the
setu payload. `ATTACH` carries only buffer metadata. The lib never touches
an fd.

## What setu is NOT

- **Not a compositor.** setu ships the transport primitives and the client
  every app uses; surface management, compositing and input routing live in
  aethersafha.
- **Not agent-aware.** No MCP / bote / t-ron / daimon concept. Introspection
  and drive-verbs ride the separate agent plane.
- **Not the paradigm.** Window/interaction model (tiling vs floating) is a
  compositor UX call; setu is paradigm-agnostic — it moves surfaces, buffers,
  and input, nothing more.

## Building & testing

```bash
cyrius deps                                            # resolve stdlib into lib/
cyrius build programs/smoke.cyr build/setu-smoke        # link-check
cyrius build programs/codec_test.cyr build/codec_test   # a RUN test
./build/codec_test                                      # exit 0 = PASS
cyrius distlib                                          # regenerate dist/setu.cyr + dist/setu.deps
sh scripts/sync-deps-sidecar.sh                         # rewrite dist/setu.deps from [deps].stdlib
```

setu is a library, so there is no CLI binary. `[build].entry` is
`programs/smoke.cyr`, which links the whole include chain and prints a
banner: `cyrius build` proves `src/lib.cyr` parses and links. It calls
nothing, so DCE hides an undefined function in the transport;
`programs/reach_test.cyr` makes every transport entry point reachable so
that case is a build error.

Testing is headless RUN tests, the sadish/dhancha discipline. CI builds
`smoke.cyr` and every `programs/*_test.cyr` for Linux and `--agnos`, and
runs the tests on Linux. The `codec_test` RUN suite round-trips every
kind (encode→decode, assert kind + argc + args identical, incl. signed /
large args) and asserts the parser rejects a truncated frame, a bad-argc
frame, and an unknown kind. This is the proof the contract holds.

### Toolchain

The pin is `[package].cyrius` in `cyrius.cyml`; CI and the release workflow
install exactly that version. It is kept matched to dhancha, setu's primary
consumer, so the contract lib and its consumer build on the identical
compiler. `lib/` is vendored from the pinned toolchain's stdlib by
`cyrius deps` (or `cyrius lib sync --full` locally) and is not committed.

### Dependencies

Cyrius stdlib only, no external libs. The declared set is `[deps].stdlib`
in `cyrius.cyml`, and `dist/setu.deps` repeats it so consumers of
`dist/setu.cyr` are told what to have in scope. The wire codec needs none of
it: little-endian marshalling uses the `load8` / `store8` builtins.

| Module | What setu uses it for |
|---|---|
| `string` | `strlen`: error names, banners, socket paths. |
| `fmt` | `fmt_int_buf`: the `/dev/shm/setu-buf-<id>` path (`buf.cyr`, Linux). |
| `alloc` | `alloc` / `alloc_init`: message records, frame buffers, client state. |
| `io` | `getenv`: `$SETU_SOCKET` on Linux, `AGNOS_CHAN` on agnos. On agnos `io.cyr` delegates to `args_agnos.cyr`'s `_agnos_getenv` (agnos has no `/proc`), and since cyrius 6.6.6 includes that file itself. |
| `syscalls` | AF_UNIX `sys_socket` / `sys_connect` / `sys_bind` / `sys_listen` / `sys_accept4` / `sys_recvfrom` / `sys_unlinkat` (Linux); the `sys_chan_*` channel band and `sys_shm_*` buffers (agnos); `SYS_WRITE` / `SYS_EXIT`. |
| `args` | `argc()` / `args_init()` in `programs/reach_test.cyr` and `programs/unix_transport_test.cyr`. Before cyrius 6.6.6 it was also what put `_agnos_getenv` in scope for `io`'s `getenv` on agnos. |
| `vec`, `str`, `assert`, `result`, `net`, `chrono` | ⚠ Not referenced by setu's own code, and every build is clean with them undeclared (measured at 0.8.10). `vec` and `result` are compiled in regardless, because `fmt` and `io` include them. `net` and `result` served the TCP transport removed in 0.8.4; `chrono` backed the agnos read-retry sleep removed in 0.8.2; `vec` / `str` / `assert` date from the scaffold. They stay declared (and so stay in `dist/setu.deps`) until a deliberate prune, because dropping one changes what consumers are told to declare. |

## Roadmap

- **v0.1.0 — scaffold (current).** Full message ABI + pure codec +
  RUN test.
- **v0.2+ — co-designed with the display slice.** setu grows only if the
  *contract* needs a new field (e.g. a format/keysym-space note). The
  aethersafha `accept` + surface registry and dhancha's real
  `dh_surface_present` / transport-fd `dh_run` land on *their* sides,
  consuming this contract. Transport stays out of the lib. GPU present and
  pointer-on-agnos are later cuts behind the same `ATTACH`.

## Relationship to other repos

- **dhancha** (client) and **aethersafha** (compositor) both link setu — the
  wire has exactly one definition.
- Design rationale: `agnosticos/docs/development/planning/native-display-protocol.md`
  (§2 = setu scope, §5 = lib intent); `dhancha/docs/development/sovereign-desktop.md`;
  the Wayland-refusal rationale in `agnosticos/docs/design-patterns.md`.
