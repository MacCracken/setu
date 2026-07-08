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

A contract lib is small on purpose — types + a codec, no I/O.

| Module | Role |
|---|---|
| `src/error.cyr` | `SetuErr` — the shared error vocabulary (`SETU_OK` / `_ERR_OOM` / `_ERR_BADMSG` / `_ERR_SHORT` / `_ERR_UNSUPPORTED` / `_ERR_OTHER`). |
| `src/proto.cyr` | `SetuMsgKind` (11 kinds), the `SetuMsg` record `{ kind, argc, args[8] }`, per-kind constructors, the expected-argc table, validation. |
| `src/codec.cyr` | `setu_encode` / `setu_decode` / `setu_encoded_len` + the LE i64 byte marshalling. Pure, allocation-light, bounds-checked. |

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

- **Not a transport.** No sockets, no `SCM_RIGHTS` marshalling, no I/O. The
  Unix-domain control+event socket + memfd/shm buffers live on each side
  (dhancha owns the client binding; aethersafha owns the server accept).
- **Not agent-aware.** No MCP / bote / t-ron / daimon concept. Introspection
  and drive-verbs ride the separate agent plane.
- **Not the paradigm.** Window/interaction model (tiling vs floating) is a
  compositor UX call; setu is paradigm-agnostic — it moves surfaces, buffers,
  and input, nothing more.

## Building & testing

```bash
cyrius deps                                            # resolve stdlib into lib/
cyrius build programs/smoke.cyr build/setu-smoke        # link-check
cyrius build programs/codec_test.cyr build/codec_test   # the RUN test
./build/codec_test                                      # exit 0 = PASS
cyrius distlib                                          # regenerate dist/setu.cyr
```

The `codec_test` RUN suite round-trips every kind (encode→decode, assert
kind + argc + args identical, incl. signed / large args) and asserts the
parser rejects a truncated frame, a bad-argc frame, and an unknown kind.
This is the proof the contract holds.

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
