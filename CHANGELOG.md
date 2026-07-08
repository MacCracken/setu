# Changelog

All notable changes to **setu** are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and this project adheres
to [Semantic Versioning](https://semver.org/).

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
