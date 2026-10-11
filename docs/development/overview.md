# setu — development overview

> setu (सेतु — *bridge*) is the AGNOS **native display-protocol contract
> lib** — the wire between GUI clients and the `aethersafha` compositor. Its
> messages are **only** pixel / input / surface-lifecycle **types**; alongside
> them it ships a pure wire **codec**, the shared-buffer present path and the
> one transport every client shares. It is **agent-free by design**.

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
| `src/buf.cyr` | The shared-buffer present path: pixels travel out-of-band, keyed by an integer id (agnos kernel shm; a `/dev/shm` file on Linux). On Linux the name is untrusted ground (0.8.13): the create is `O_EXCL` and skips a name that exists, and the reopens are `O_NONBLOCK \| O_NOFOLLOW` and accept only a regular file, judged on the descriptor they opened. |
| `src/client.cyr` | The reference transport every client uses: the `#97` channel band on agnos (the compositor endows the channel at spawn), AF_UNIX `SOCK_SEQPACKET` on Linux, where it also provides the listen / accept side. Every read that waits takes a deadline (`setu_read_blk_ms` / `setu_read_msg_ms`; the defaults are 8 s on agnos and none on Linux), and every socket it opens on Linux is close-on-exec. |

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
| `SETU_ATTACH` (5) | C→S | id, w, h, stride, fmt, buf_id |
| `SETU_COMMIT` (6) | C→S | id |
| `SETU_CLOSE` (7) | C↔S | id |
| `SETU_INPUT_KEY` (8) | S→C | id, keysym, mods |
| `SETU_INPUT_PTR_MOVE` (9) | S→C | id, x, y |
| `SETU_INPUT_PTR_BTN` (10) | S→C | id, button, state |
| `SETU_INPUT_FOCUS` (11) | S→C | id, focused |
| `SETU_INPUT_PTR_SCROLL` (12) | S→C | id, delta (signed; + = wheel-up) |

**`SETU_ATTACH` names a shared buffer; no fd is passed.** The present path
keeps pixels off the wire, and there is no `SCM_RIGHTS`. `buf_id` (arg5,
`setu_attach_buf`) is the integer id of a kernel/OS-owned buffer from
`src/buf.cyr` — agnos kernel shm (`sys_shm_*`), `/dev/shm/setu-buf-<id>` on
Linux — that the client writes and the compositor reads by id; a plain
integer crosses both transports unchanged. `buf_id = 0` is the legacy inline
form (`setu_attach`): pixels follow the frame. It is retired, since setu sends
at most 64 bytes per record on both targets and no real surface fits; the
client never sends it and aethersafha refuses it. The connection fd belongs to
`client.cyr`.

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
cyrius distlib --check                                  # is the committed dist/ current? (writes nothing)
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
`read_deadline_test` measures the read deadlines against forked peers and
takes about 9 s, most of it one check that the Linux default is still waiting
past the agnos default (8 s). It arms a 60 s watchdog, because a regression
there is a hang rather than a wrong answer. `buf_safety_test` plants a FIFO, a
symlink, a directory, a leased file, a short file and a stale file at buffer
names and times each refusal. It arms a 30 s watchdog for the same reason,
which also removes what it planted. `zero_alloc_test` reads the allocator's own
count (`alloc_used()`) around 10,000 calls of each per-message and per-frame
function over a real connection, and requires 0 bytes.

Commit `dist/` exactly as `cyrius distlib` writes it. CI fails if either
file differs from a fresh regeneration (`cyrius distlib --check`), if the
bundle does not compile, or if `dist/setu.deps` omits a declared
`[deps].stdlib` leaf.

### Toolchain

The pin is `[package].cyrius` in `cyrius.cyml`; CI and the release workflow
install exactly that version. It is kept matched to dhancha, setu's primary
consumer, so the contract lib and its consumer build on the identical
compiler. `lib/` is vendored from the pinned toolchain's stdlib by
`cyrius deps` (or `cyrius lib sync --full` locally) and is not committed.

### Dependencies

Cyrius stdlib only, no external libs. The declared set is `[deps].stdlib`
in `cyrius.cyml`. `cyrius distlib` writes it into `dist/setu.deps`, together
with any stdlib leaf `src/lib.cyr` includes, so consumers of
`dist/setu.cyr` are told what to have in scope. The wire codec needs none of
it: little-endian marshalling uses the `load8` / `store8` builtins.

| Module | What setu uses it for |
|---|---|
| `string` | `strlen`: error names, banners, socket paths. |
| `fmt` | `fmt_int_buf`: the `/dev/shm/setu-buf-<id>` path (`buf.cyr`, Linux). |
| `alloc` | `alloc` / `alloc_init`: message records from the constructors, client state, and the one-time buffers of connect, listen, the first poll and the first present. Since 0.8.13 no per-message or per-frame call allocates; their frame buffers are function-local. `zero_alloc_test` reads `alloc_used()`. |
| `io` | `getenv`: `$SETU_SOCKET` on Linux, `AGNOS_CHAN` on agnos. On agnos `io.cyr` delegates to `args_agnos.cyr`'s `_agnos_getenv` (agnos has no `/proc`), and since cyrius 6.6.6 includes that file itself. |
| `syscalls` | AF_UNIX `sys_socket` / `sys_connect` / `sys_bind` / `sys_listen` / `sys_accept4` / `sys_recvfrom` / `sys_unlinkat` and `EAGAIN` / `EINTR` (Linux); `sys_open` / `sys_fstat` with the per-arch `O_*` flags (`O_NOFOLLOW` differs between x86_64 and arm64, and is named in the stdlib since cyrius 6.6.4), `STAT_MODE` / `STAT_SIZE` and `EEXIST` for the `/dev/shm` buffers (Linux, 0.8.13); the `sys_chan_*` channel band, `sys_shm_*` buffers and the read-deadline clocks `sys_uptime_us` / `sys_uptime_ms` (agnos); `SYS_WRITE` / `SYS_EXIT`. poll(2) has no wrapper, so the Linux read spells it `syscall(7, …)` as the stdlib does; the aarch64 backend rewrites that to ppoll. |
| `chrono` | `clock_now_ns`: the monotonic clock behind the Linux read deadline (0.8.12), included from `src/lib.cyr`. `read_deadline_test` also times the reads with `clock_now_ms` and paces its peers with `sleep_ms`; `buf_safety_test` times its refusals with `clock_now_ns` and paces its watchdog with `sleep_ms`. It backed the agnos read-retry sleep until 0.8.2 and was unreferenced from then until 0.8.12. |
| `args` | `argc()` / `args_init()` in `programs/reach_test.cyr`, `programs/unix_transport_test.cyr`, `programs/read_deadline_test.cyr`, `programs/buf_safety_test.cyr` and `programs/zero_alloc_test.cyr`. Before cyrius 6.6.6 it was also what put `_agnos_getenv` in scope for `io`'s `getenv` on agnos. |
| `vec`, `str`, `assert`, `result`, `net` | ⚠ Not referenced by setu's own code, and every build is clean with them undeclared (measured at 0.8.10). `vec` and `result` are compiled in regardless, because `fmt` and `io` include them. `net` and `result` served the TCP transport removed in 0.8.4; `vec` / `str` / `assert` date from the scaffold. They stay declared (and so stay in `dist/setu.deps`) until a deliberate prune, because dropping one changes what consumers are told to declare. For `vec` / `str` / `assert` that also means removing their `src/lib.cyr` includes: distlib's include scan keeps an included leaf in the sidecar even when it is undeclared (measured on 6.6.6). |

## Roadmap

- **Current.** Full message ABI (12 kinds) + pure codec + RUN tests, the
  shared-buffer present path, and the reference transport on both targets:
  the `#97` channel band on agnos, AF_UNIX `SOCK_SEQPACKET` on Linux. How it
  got here is in `CHANGELOG.md`.
- **Next — contract-driven.** setu grows only if the *contract* needs a new
  field or kind (e.g. a format/keysym-space note), appended without
  renumbering, as `SETU_INPUT_PTR_SCROLL` was in 0.8.8.

## Relationship to other repos

- **aethersafha** (compositor) and its clients — **dhancha** (widget toolkit),
  **puka** (terminal) and **crab** (file manager) — all link setu, so the
  wire has exactly one definition.
- Design rationale: `agnosticos/docs/development/planning/native-display-protocol.md`
  (§2 = setu scope, §5 = lib intent); `dhancha/docs/development/sovereign-desktop.md`;
  the Wayland-refusal rationale in `agnosticos/docs/design-patterns.md`.
