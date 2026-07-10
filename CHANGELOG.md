# Changelog

All notable changes to **setu** are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and this project adheres
to [Semantic Versioning](https://semver.org/).

## [0.3.2] — 2026-07-09 — non-blocking client input poll (the S→C input channel)

Clients can now REACT to input the compositor forwards to them without stalling their render
loop. This is the client half of **input-over-setu** (the compositor's forwarding half ships
in aethersafha 0.8.2): the compositor sends a `SETU_INPUT_KEY` frame to the focused surface's
connection, and the client drains it non-blocking each frame. The `SETU_INPUT_*` constructors
already existed (0.3.1); what was missing was a way for a client to poll for them without
blocking its animation loop.

### Added

- **`setu_poll_input(fd, msg_out)`** — a NON-BLOCKING single-recv poll for one inbound frame.
  On agnos `sock_recv`#49 returns 0 for would-block, so an empty channel returns immediately
  (0) and the client's animate loop never blocks; a frame returns 1 with `msg_out` filled, and
  EOF/error returns -6. The compositor sends one small `SETU_INPUT_*` frame per event over
  loopback, so a single recv delivers a whole frame (no reassembly at this milestone).
- **`programs/present_probe.cyr` reacts to forwarded keys** — latches on `SETU_INPUT_KEY` and
  flips its border + bar to WHITE, the on-screen proof that a keystroke routed through setu to
  the focused window. Validated on agnos by an injection harness (`setu-input-test.py`) that
  boots with a QEMU USB-xHCI keyboard and drives `sendkey`.

## [0.3.1] — 2026-07-09 — SHARED-BUFFER present (out-of-band pixels) + the on-device tagged-fd read/write fix

The present path stops streaming pixels inline over the socket and hands them to the
compositor through a **shared buffer** referenced by id. On agnos this is what makes a
real surface composite: a hundreds-of-KB inline pixel payload can't drain through the 2 KB
`TCP_RX_RING` while the single-CPU sender holds preemption in `sock_send`#48 — it deadlocks.
Shared-buffer sidesteps it (and is lower-copy). The `setu_serve_probe`+`present_probe`
round-trip is proven on Linux, and `aethersafha-setu-smoke.sh` is **green on the sovereign
kernel**. Cyrius pin **6.4.25 → 6.4.34** (for the native `sys_shm_*` wrappers).

### Added

- **`src/buf.cyr` — the shared-buffer backend** (`setu_buf_create` / `_write` / `_read` /
  `_close`), COPY-based + agnostic. Linux = a `/dev/shm/setu-buf-<id>` tmpfs file (write()/
  read()); agnos = the kernel shm band via the native `sys_shm_create`/`_write`/`_read`/`_free`
  (`#71-74`, agnos 1.53.9). Kernel/OS-OWNED buffers, so a client exiting right after present
  can't free a page the compositor is still reading (no cross-proc page-map lifetime hazard).
- **`setu_attach_buf(id, w, h, stride, fmt, buf_id)`** — ATTACH that references a shared buffer.

### Changed

- **`SETU_ATTACH` carries `buf_id` (arg5), argc 5→6.** `0` = inline pixels follow the frame
  (legacy path, kept as the multi-core fallback); `> 0` = the pixels live in shared buffer
  `buf_id`. `setu_client_present` now takes the shared-buffer path (create → write → ATTACH-by-id
  → COMMIT), falling back to the inline stream only when the buffer backend is unavailable.

### Fixed

- **The agnos tagged-fd data plane.** `setu_write_all`/`setu_read_blk` used the raw primitive
  `syscall(SYS_WRITE/SYS_READ)` on a **userland tagged connect-fd** (`0x40000000|slot` from
  `net.cyr`), which the kernel rejects at the `vfs_write`/`vfs_read` `fd_idx >= 32` bound before
  the `VFS_SOCK → tcp_send/tcp_recv` dispatch — so on agnos the first client→compositor write
  failed (`rc=-41`) and the compositor could never read a client frame. Now they call the
  tagged-fd-aware `sys_write`/`sys_read` (setu already links `net`+`syscalls`; Linux `sys_write`
  is a plain `write`, so it stays portable). This is what let the on-device present complete.

## [0.3.0] — 2026-07-08

The reference transport goes **cross-platform** (item 3b of the road-to-desktop):
setu now speaks **TCP over loopback** (`127.0.0.1 : 7700`) on Linux **and** on
agnos, so the sovereign desktop runs on the sovereign kernel — not just the host.
This **replaces** the 0.2.0 AF_UNIX client, which was Linux-only and fail-closed
on agnos. Proven end-to-end: `puka` (client) connects over TCP and presents a
rendered 320×192 terminal frame → `aethersafha`'s server accepts (non-blocking
poll) and composites it → a valid PPM with real content (grey grid on black).

### Added

- **Server transport in `client.cyr`** — the compositor half now lives beside the
  client so both sides share one wire definition:
  - `setu_listen(path)` — `tcp_socket` + `sock_bind` + `sock_listen` on
    `loopback:7700`; sets the fd non-blocking on Linux (agnos accept is already
    non-blocking) so the frame loop never stalls. Returns the listening fd or a
    negative step code.
  - `setu_accept(sfd)` — non-blocking accept; the client fd (≥ 0) or `-5`
    (`WOULD_BLOCK`, poll again) on **both** targets.
  - `setu_write_all(fd, buf, n)` — writes exactly `n` bytes, looping over partial
    sends (agnos `sock_send` #48 may send < len — a large pixel payload can't go
    in one syscall).
- **`SETU_TCP_PORT`** (`7700`) — the compositor's single well-known loopback port
  (the desktop has one compositor endpoint; `path` params are kept for API
  compatibility but are advisory).

### Changed

- **`setu_connect` is now TCP** — `tcp_socket` + `sock_connect(loopback, 7700)`
  via `net.cyr`, replacing the AF_UNIX `connect(sockaddr_un)` path. Same
  signature; `path` is advisory.
- **`setu_read_blk` absorbs agnos's non-blocking recv** — on agnos `sock_recv`
  (#49) returns `0` for would-block / `-1` for EOF (inverted from Linux's `0` =
  EOF), so the agnos branch retries-with-yield (bounded, `sleep_ms`) instead of
  treating `0` as EOF. Linux behaviour is byte-identical to before.
- **Deps** — `cyrius.cyml` gains `net` (sockets), `result` (`is_ok` /
  `result_unwrap`), and `chrono` (the portable `sleep_ms` yield).

### Removed

- **`setu_cl_sockaddr`** (the `sockaddr_un` builder) — obsolete under TCP; there
  is no socket path to marshal. **Breaking:** consumers that referenced it must
  drop the call (the address is now the implicit `loopback:7700`). `dhancha`'s
  `dh_setu_sockaddr` forwarder was removed to match.

## [0.2.0] — 2026-07-08

The reference **client transport** joins the lib: setu is now the protocol
CONTRACT (proto/codec) **plus** its reference client, so both consumers —
`dhancha` (toolkit) and `puka` (terminal) — share one implementation instead of
duplicating it.

### Added

- **`src/client.cyr`** — setu's reference CLIENT transport, promoted in from
  dhancha's `dh_setu_*` / `DhClient` (a MOVE, generalized to raw buffers).
  - **Framing primitives** — `setu_connect` (AF_UNIX; agnos-guarded, fail-closes
    until the agnos transport 3b lands), `setu_send`, `setu_recv`,
    `setu_read_exact`, `setu_read_msg` (length-framed stream read), and the pure
    `setu_cl_sockaddr` (`sockaddr_un` builder).
  - **`SetuClient`** — the persistent, RAW-BUFFER app handle:
    `setu_client_connect` → `setu_client_present(pix, w, h)` (lazily
    `CREATE_SURFACE` on first present, then `ATTACH` + inline pixels + `COMMIT`)
    → `setu_client_recv` (one framed setu message) → `setu_client_close`.
    Consumers layer their own render on top and present raw buffers.
- **`programs/client_test.cyr`** — RUN test for the pure `setu_cl_sockaddr`
  layout + long-path clamp. (The socket ops are proven end-to-end by the
  `puka` ↔ `aethersafha` integration.)

### Changed

- **setu is no longer I/O-free.** The lib now ships the reference client (the
  codec remains pure/host-testable). `src/lib.cyr` + `[lib].modules` include
  `client.cyr`; both Linux and `--agnos` build clean (the `setu_connect` agnos
  guard compiles without referencing Linux socket numbers). README + lib header
  updated. **Agent-free by construction is unchanged.**

## [0.1.0] — 2026-07-07

Initial scaffold — the AGNOS native display-protocol contract lib: the
`dhancha` client ↔ `aethersafha` compositor wire. Pure message **types** +
a pure wire **codec**, headless RUN-testable. **No I/O in the lib**
(transport lives on each side). **Agent-free by design** — no agent / MCP
concept rides this plane.

### Added

- **`src/error.cyr`** — the shared error vocabulary. `SetuErr` 16-byte
  record `{ code, detail }`; codes `SETU_OK` / `SETU_ERR_OOM` /
  `SETU_ERR_BADMSG` / `SETU_ERR_SHORT` / `SETU_ERR_UNSUPPORTED` /
  `SETU_ERR_OTHER`; `setu_err_new` / `setu_err` / accessors /
  `setu_err_name` / `setu_err_print_name`. The codec returns codes
  **negated** on the hot path (allocation-free); this record is for
  consumers that want carried context.
- **`src/proto.cyr`** — the message model. `SetuMsgKind` enum (11 kinds,
  values 1–11, frozen): `SETU_HELLO`, `SETU_CREATE_SURFACE`,
  `SETU_SURFACE_CREATED`, `SETU_CONFIGURE`, `SETU_ATTACH`, `SETU_COMMIT`,
  `SETU_CLOSE`, `SETU_INPUT_KEY`, `SETU_INPUT_PTR_MOVE`,
  `SETU_INPUT_PTR_BTN`, `SETU_INPUT_FOCUS`. The `SetuMsg` record
  `{ kind, argc, args[8] }` (80 bytes) with accessors; per-kind
  constructors (`setu_hello` … `setu_input_focus`) filling args in ABI
  order; the `setu_kind_argc` expected-argc table; `setu_kind_valid`;
  `setu_msg_validate` (known kind + argc matches table); `setu_kind_name`
  (diagnostics).
  - **`SETU_ATTACH` fd is out-of-band.** The pixel buffer's memfd/shm fd
    is passed via `SCM_RIGHTS` over the transport, **not** in the setu
    payload; `ATTACH` carries only `id, w, h, stride, fmt`. Documented in
    `proto.cyr` and the README.
- **`src/codec.cyr`** — the pure wire codec. Frame =
  little-endian i64 `[kind][argc][args…argc]` = `(2+argc)*8` bytes.
  - `setu_encode(msg, out_buf, out_cap)` → non-negative length or negated
    `SetuErr`; validates the message, then bounds-checks every write
    against `out_cap` (too-small → `SETU_ERR_SHORT`).
  - `setu_decode(in_buf, in_len, msg_out)` → consumed length or negated
    `SetuErr`. **Hardened wire parser over untrusted bytes:** header
    presence checked before reading kind/argc; kind range- + table-checked;
    **argc validated against the per-kind table before it sizes any read**
    (a forged huge argc can never drive an out-of-bounds loop); full-frame
    presence checked; only then are args committed. Unused arg slots are
    zeroed so a reused `msg_out` has no stale tail.
  - `setu_encoded_len(msg)` — the exact frame size of a valid message.
  - `setu_put_i64` / `setu_get_i64` — endianness-explicit, sign-correct
    little-endian i64 marshalling via `store8`/`load8` + `& 0xFF` masking
    and per-byte shifts (correct for negative values, unlike `% 256` /
    `/ 256`).
- **`src/lib.cyr`** — the include chain (stdlib includes live only here;
  domain modules flat in dependency order: error → proto → codec) so
  `cyrius distlib` bundles a compile-clean `dist/setu.cyr`.
- **`programs/smoke.cyr`** — link-check entry (bare-`main()` + `SYS_EXIT`
  form, host- and agnos-correct).
- **`programs/codec_test.cyr`** — the RUN test proving the scaffold:
  round-trips **every** message kind (encode→decode, assert kind + argc +
  every arg identical, including negative and near-32-bit-max args) and
  asserts the parser **rejects** a truncated frame (`SETU_ERR_SHORT`), a
  header-only truncation, a bad-argc frame (`SETU_ERR_BADMSG`), an unknown
  kind, a below-range kind, and a too-small encode buffer. Exit code =
  failed checks (0 = PASS).
- **`dist/setu.cyr`** — the bundled distribution (`cyrius distlib`).
- Repo scaffolding: `cyrius.cyml` (pin `6.4.7`, minimal stdlib set,
  `[lib]` module order, `[build]` smoke entry), `README.md`, this
  changelog, `docs/development/overview.md`, `.github/workflows/ci.yml`,
  `LICENSE` (GPL-3.0-only), `.gitignore`, `VERSION`.

### Notes

- The message ABI (kind values + per-kind arg order) is **frozen** for the
  0.x line — the codec test guards it. Growth beyond the scaffold happens
  only if the *contract* needs a new field; transport stays out of the lib.
