# setu

Version: 0.8.11

**setu** (सेतु — Sanskrit/Hindi: *bridge*) is the pure-Cyrius **native
display-protocol** for AGNOS — the wire between GUI clients and the
`aethersafha` compositor. It carries the pixel, input, and surface-lifecycle
message **types**, a pure wire **codec** (marshal / unmarshal as pure,
host-testable functions), and — since **v0.2.0** — the **reference client
transport** (`client.cyr`): the persistent connection every app owns
(`setu_client_connect` → `setu_client_present` → `setu_client_recv` →
`setu_client_close`).

> ## ⛔ TCP over loopback is a RETIRED WRONG PREMISE (2026-08-03), removed in 0.8.4
>
> From **v0.3.0** until **v0.8.4** that transport was **TCP over loopback** (`127.0.0.1 : 7700`) via
> the cyrius `net.cyr` socket layer. **That was the wrong choice**, made because a TCP stack
> happened to exist, never put to the operator, and then carried for a month behind six
> accommodations. A local display protocol has nothing to route, nothing to checksum, no window
> to negotiate, and **no business owning a port**.
>
> ⛔ **Before agnos 1.56.34 it could not complete on an ordinary boot.** The SYN-ACK came back
> addressed to `net_ip` and `tcp_find_conn` never matched. The one test that showed it green in
> that era, `aethersafha-setu-smoke.sh`, passed **by accident**: the kernel hook
> `AETHERSAFHA_SETU_SELFTEST` assigned `net_ip = 0x7F000001` first. **Every "proven on the
> sovereign kernel" claim tied to that smoke is a FALSE GREEN.** Hook and smoke were deleted
> 2026-08-03.
>
> ⚠ **After the kernel fix it DID connect, un-rigged — and that is not why it is retired.** agnos
> 1.56.34's `net_src_for` derives an outbound segment's source from its destination, so a loopback
> SYN goes out `src = dst = 127.0.0.1`. On **2026-08-02**, on 1.56.34+, agnos
> `scripts/harness/aethersafha-clients-test.py` reached **`connected: 2, presented: 2`** — setu's
> own `present_probe` (staged as `/bin/puka`) and the real dhancha `crab` both connected and
> presented. That harness byte-scans `build/agnos` and hard-exits if the kernel carries any
> selftest hook, and attaches a virtio NIC so DHCP yields a real `net_ip`; **it is the harness that
> caught the rigging**, so its green is honest. ⚠ Scope it exactly: **QEMU at `-smp 1`**, never
> shown on iron, and `-smp 4` fault-kills.
>
> ⛔ **The ruling is architectural, not empirical.** This transport is retired for being the **wrong
> primitive** (operator ruling, 2026-08-03), not for being broken. "It connects" was never the bar.
>
> ⭐ **The replacement is the agnos socket — `anu`**, designed in agnos
> [`docs/development/planning/ipc.md`](https://github.com/MacCracken/agnos/blob/main/docs/development/planning/ipc.md)
> §9: a channel handed to the child at spawn, not an address dialled over a network stack.
>
> ⭐ **TCP is gone from setu on both targets.** Since **0.8.0** the agnos client dials nothing: the
> compositor mints a `#97` channel, endows one end and spawns the client holding it, and
> `setu_connect` reads that fd from `AGNOS_CHAN`, refusing on a kernel without the band. Since
> **0.8.4** Linux speaks AF_UNIX / `SOCK_SEQPACKET` — the primitive was wrong for the problem, not
> for the kernel — rendezvousing on a filesystem path (`$SETU_SOCKET`, else
> `/tmp/setu-display.sock`). Both are local, connected **record** transports: each send is one
> record carrying one frame, and a frame that does not fit one 64-byte record is an error on both,
> so a consumer cannot be correct on one target and broken on the other for a framing reason. CI's
> `scripts/check-no-tcp-on-agnos.sh` fails if a TCP symbol returns to agnos-active code.
>
> ⚠ **Unaffected:** the setu **codec / message ABI** (pure, transport-agnostic, survives the swap
> untouched) and the **shared-buffer present path** (`buf.cyr` — the pixels already left this wire).

The codec
stays pure; the client is the **one**
implementation every client shares (dhancha, puka, crab) — `dhancha` renders
widgets → pixels, `puka` renders a cell grid → pixels, and each presents raw
buffers through it — so the transport has a single definition, not one per
consumer. The compositor side lives in `aethersafha`. On Linux `client.cyr` also
provides the listen / accept side; on agnos nothing is accepted, because the
compositor endows each client's channel at spawn. Because the contract has
exactly one definition, both sides agree on the wire by construction.

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
| `SETU_ATTACH` | C→S | id, w, h, stride, fmt, buf_id |
| `SETU_COMMIT` | C→S | id |
| `SETU_CLOSE` | C↔S | id |
| `SETU_INPUT_KEY` | S→C | id, keysym, mods |
| `SETU_INPUT_PTR_MOVE` | S→C | id, x, y |
| `SETU_INPUT_PTR_BTN` | S→C | id, button, state |
| `SETU_INPUT_FOCUS` | S→C | id, focused |
| `SETU_INPUT_PTR_SCROLL` | S→C | id, delta (signed; + = wheel-up) |

**`SETU_ATTACH` and the pixel buffer.** The present path keeps pixels off
the setu wire, and no fd travels with them: there is no `SCM_RIGHTS`. The
client copies each frame into a **shared buffer** (`src/buf.cyr`) owned by the
kernel/OS and keyed by an integer id — kernel shm (`sys_shm_*`) on agnos, a
`/dev/shm/setu-buf-<id>` tmpfs file on Linux. `ATTACH` names it in its sixth
arg, `buf_id` (`setu_attach_buf`), and the compositor reads the pixels by that
id. The id is a plain integer, so it crosses both transports unchanged.
`buf_id = 0` is the legacy inline form (`setu_attach`), in which pixels follow
the frame. It is retired: setu sends at most 64 bytes per record on both
targets, which no real surface fits, so the client never sends it and
aethersafha refuses it. When no shared buffer can be made or written,
`setu_client_present` returns -45 or -46 and sends nothing. The connection fd
belongs to `client.cyr`, which holds it from connect (on agnos, from spawn) to
close.

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

- **Current.** A buildable, RUN-tested pure-Cyrius contract plus the
  present path and transport every client shares, built for Linux and
  `--agnos`.
  - `src/error.cyr` — `SetuErr` model (`SETU_OK` / `_ERR_OOM` /
    `_ERR_BADMSG` / `_ERR_SHORT` / `_ERR_UNSUPPORTED` / `_ERR_OTHER`), a
    16-byte record, and `setu_err_name`.
  - `src/proto.cyr` — `SetuMsgKind` (the 12 message kinds), the `SetuMsg`
    record `{ kind, argc, args[8] }`, per-kind constructors
    (`setu_hello` … `setu_input_focus`), the `setu_kind_argc` expected-argc
    table, `setu_msg_validate`, and the `CREATE_SURFACE` flag bits
    (`SETU_SURF_FULL_KEYS`, `SETU_SURF_PREMULTIPLIED`).
  - `src/codec.cyr` — the pure, allocation-light wire codec:
    `setu_encode` (message → bounds-checked frame), `setu_decode`
    (untrusted frame → validated message), `setu_encoded_len`, and the
    little-endian i64 byte marshalling (`setu_put_i64` / `setu_get_i64`).
  - `src/buf.cyr` — the shared-buffer present path: `setu_buf_create` /
    `_write` / `_read` / `_close`.
  - `src/client.cyr` — the transport (`setu_connect`, plus `setu_listen` /
    `setu_accept` on Linux) and the `SetuClient` handle
    (`setu_client_connect` → `setu_client_present` →
    `setu_client_poll_input` / `setu_client_recv` → `setu_client_close`).
  - `programs/smoke.cyr` — the link-check entry.
  - `programs/codec_test.cyr` — the RUN test: round-trips **every** kind
    (encode→decode, assert kind + argc + args identical, incl. signed /
    large args) and asserts the parser **rejects** a truncated frame, a
    bad-argc frame, and an unknown kind.
  - `programs/client_test.cyr` (`sockaddr_un`, input reassembly, buffer
    lifecycle) and `programs/unix_transport_test.cyr` (a real AF_UNIX /
    `SOCK_SEQPACKET` round-trip whose record boundaries must survive) —
    further RUN tests. `programs/reach_test.cyr` makes every transport
    entry point reachable, so an undefined symbol is a build error on
    either target rather than a warning DCE hides.
  - `programs/present_probe.cyr` — a slim reference client.
- **Next.** setu grows only if the *contract* needs it (e.g. a keysym-space
  note, a format enum), and only by appending: kind values and arg order
  are never renumbered, which is how `SETU_INPUT_PTR_SCROLL` arrived in
  0.8.8.

## Place in the stack

```
   dhancha            ← client-side widget toolkit (renders a surface)
      │  encodes/decodes messages via
     setu              ← the display-protocol contract (this repo)
      │  same lib on both sides, transport included (#97 channel on agnos, AF_UNIX SEQPACKET on Linux)
   aethersafha         ← compositor / server (composites to screen)
```

The **agent** plane is a *separate* endpoint (aethersafha as a `bote` MCP
host, gated by `t-ron`, driven by `daimon`) — it shares **no wire and no
message type** with setu.

## Consumers

- **dhancha** — the widget-toolkit client: encodes `CREATE_SURFACE` / `ATTACH` / `COMMIT`,
  decodes `CONFIGURE` + input events into its `DhQueue`.
- **puka** (terminal) and **crab** (file manager) — clients presenting through
  the same `client.cyr`.
- **aethersafha** — the compositor: decodes client requests into `win_*`
  operations, encodes `CONFIGURE` + input events to the focused client.

All of them link the **same** setu, so the wire has one definition.

## Dependencies

- **Cyrius stdlib only** — the set declared in `cyrius.cyml` `[deps].stdlib`,
  resolved by `cyrius deps` into `lib/`. No external library deps — setu is
  a pure-Cyrius leaf contract. What each module is for:
  [`docs/development/overview.md`](docs/development/overview.md#dependencies).

The toolchain pin is `[package].cyrius` in `cyrius.cyml`, kept matched to the
dhancha client ([Toolchain](docs/development/overview.md#toolchain)).

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
