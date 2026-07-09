# setu

Version: 0.3.0

**setu** (सेतु — Sanskrit/Hindi: *bridge*) is the pure-Cyrius **native
display-protocol** for AGNOS — the wire between GUI clients and the
`aethersafha` compositor. It carries the pixel, input, and surface-lifecycle
message **types**, a pure wire **codec** (marshal / unmarshal as pure,
host-testable functions), and — since **v0.2.0** — the **reference client
transport** (`client.cyr`): the persistent connection every app owns
(`setu_client_connect` → `setu_client_present` → `setu_client_recv` →
`setu_client_close`). Since **v0.3.0** that transport is **TCP over loopback**
(`127.0.0.1 : 7700`) via the cyrius `net.cyr` socket layer — CROSS-PLATFORM by
construction: it routes to Linux BSD sockets on the host AND to agnos's kernel
TCP band (`sock_connect`/`sock_listen`/`sock_accept`, tagged-fd send/recv) on
the sovereign kernel, so the desktop runs on agnos, not just Linux (this
replaced the Linux-only AF_UNIX path, which fail-closed on agnos). The codec
stays pure; the client is the **one**
implementation both consumers share — `dhancha` renders widgets → pixels,
`puka` renders a cell grid → pixels, and both present raw buffers through it —
so the transport has a single definition, not one per consumer. The compositor
SIDE (accept / serve) lives in `aethersafha`. Because the contract has exactly
one definition, both sides agree on the wire by construction.

It is **agent-free by design.** No agent / MCP concepts ride this plane.
Surface introspection and drive-verbs ride a **separate** `bote` / `t-ron` /
`daimon` endpoint (the agent plane). Keeping the display wire agent-free is
what keeps the AGNOS desktop **AI-optional by construction** — a plain GUI
app speaks only setu and never touches an agent concept ("the OS stands on
its own with zero AI").

setu is the display half of the sovereign-desktop seam described in
[`agnosticos/docs/development/planning/native-display-protocol.md`](https://github.com/MacCracken/agnosticos)
(§2 is setu's scope; §5 is the lib intent).

## What setu carries

The message set, designed 1:1 against the real surfaces on both sides (the
compositor `Window` / `W_ID`, the client `DhSurface`, and dhancha's
`DhEvent` / `DhEventKind`):

| Kind | Dir | Args (in order) |
|---|---|---|
| `SETU_HELLO` | C↔S | version, role |
| `SETU_CREATE_SURFACE` | C→S | w, h, flags |
| `SETU_SURFACE_CREATED` | S→C | id |
| `SETU_CONFIGURE` | S→C | id, w, h, state |
| `SETU_ATTACH` | C→S | id, w, h, stride, fmt |
| `SETU_COMMIT` | C→S | id |
| `SETU_CLOSE` | C↔S | id |
| `SETU_INPUT_KEY` | S→C | id, keysym, mods |
| `SETU_INPUT_PTR_MOVE` | S→C | id, x, y |
| `SETU_INPUT_PTR_BTN` | S→C | id, button, state |
| `SETU_INPUT_FOCUS` | S→C | id, focused |

**`SETU_ATTACH` and the pixel-buffer fd.** The memfd/shm file descriptor
that backs the pixel buffer is passed **out-of-band** over the transport
socket via `SCM_RIGHTS` ancillary data — it is **not** part of the setu
payload. `ATTACH` carries only the buffer *metadata* (id, w, h, stride,
fmt); the receiving side pairs the next `SCM_RIGHTS` fd with the `ATTACH`
it accompanies. The lib never touches an fd — transport ownership lives on
each side.

## The wire

A frame is a sequence of little-endian signed 64-bit words:

```
  [ kind ][ argc ][ arg0 ][ arg1 ] ... [ arg(argc-1) ]
    8B      8B      8B      8B            8B
```

so exactly `(2 + argc) * 8` bytes. `argc` **must** equal the kind's
canonical arg count — the decoder validates it against a per-kind table
*before* using it to size any read, so a forged `argc` can never drive an
out-of-bounds arg loop. `setu_decode` is a wire parser over **untrusted**
bytes: every read is bounds-checked against `in_len`, the kind is range- +
table-checked, and a short or malformed frame returns a negated `SetuErr`
(never a partial message).

## Scope

- **v0.1.0 — scaffold (this cut).** A buildable, RUN-tested pure-Cyrius
  contract: the full message ABI, constructors, the per-kind argc table,
  and the pure encode/decode codec.
  - `src/error.cyr` — `SetuErr` model (`SETU_OK` / `_ERR_OOM` /
    `_ERR_BADMSG` / `_ERR_SHORT` / `_ERR_UNSUPPORTED` / `_ERR_OTHER`), a
    16-byte record, and `setu_err_name`.
  - `src/proto.cyr` — `SetuMsgKind` (the 11 message kinds), the `SetuMsg`
    record `{ kind, argc, args[8] }`, per-kind constructors
    (`setu_hello` … `setu_input_focus`), the `setu_kind_argc` expected-argc
    table, and `setu_msg_validate`.
  - `src/codec.cyr` — the pure, allocation-light wire codec:
    `setu_encode` (message → bounds-checked frame), `setu_decode`
    (untrusted frame → validated message), `setu_encoded_len`, and the
    little-endian i64 byte marshalling (`setu_put_i64` / `setu_get_i64`).
  - `programs/smoke.cyr` — the link-check entry.
  - `programs/codec_test.cyr` — the RUN test: round-trips **every** kind
    (encode→decode, assert kind + argc + args identical, incl. signed /
    large args) and asserts the parser **rejects** a truncated frame, a
    bad-argc frame, and an unknown kind.
- **v0.2+ — next.** As the display slice is co-designed (aethersafha
  `accept` / surface registry; dhancha's real `dh_surface_present` +
  transport-fd `dh_run`), setu grows only if the *contract* needs it
  (e.g. a keysym-space note, a format enum). Transport stays out of the
  lib. GPU present and pointer-on-agnos are later cuts behind the same
  `ATTACH`.

## Place in the stack

```
   dhancha            ← client-side widget toolkit (renders a surface)
      │  encodes/decodes messages via
     setu              ← the display-protocol contract (this repo)
      │  same lib on both sides; transport (Unix socket + SCM_RIGHTS) per-side
   aethersafha         ← compositor / server (composites to screen)
```

The **agent** plane is a *separate* endpoint (aethersafha as a `bote` MCP
host, gated by `t-ron`, driven by `daimon`) — it shares **no wire and no
message type** with setu.

## Consumers

- **dhancha** — the client: encodes `CREATE_SURFACE` / `ATTACH` / `COMMIT`,
  decodes `CONFIGURE` + input events into its `DhQueue`.
- **aethersafha** — the compositor: decodes client requests into `win_*`
  operations, encodes `CONFIGURE` + input events to the focused client.

Both link the **same** setu, so the wire has one definition.

## Dependencies

- **Cyrius stdlib** — `string`, `fmt`, `alloc`, `io`, `vec`, `str`,
  `syscalls`, `assert`. Resolved by `cyrius deps` into `lib/`. No external
  library deps — setu is a pure-Cyrius leaf contract.

The toolchain pin is `cyrius = "6.4.7"` (matched to the dhancha client).

## Quick Start

```bash
cyrius deps                                       # resolve stdlib into lib/
cyrius build programs/smoke.cyr build/setu-smoke  # link-check
./build/setu-smoke                                # prints the banner

cyrius build programs/codec_test.cyr build/codec_test  # the RUN test
./build/codec_test                                     # exit 0 = PASS
```

## License

GPL-3.0-only.
