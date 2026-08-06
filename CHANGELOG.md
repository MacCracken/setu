# Changelog

All notable changes to **setu** are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and this project adheres
to [Semantic Versioning](https://semver.org/).

---

## [Unreleased] — the agnos client no longer dials anything (channel-band cutover, bite 6)

⭐⭐ **On agnos, `setu_connect` DOES NOT DIAL.** No socket, no connect, no port, no loopback address —
four executable lines: check the kernel floor, read the fd the compositor endowed us, return it. The
client is HANDED a channel at spawn. Requires **agnos >= 1.56.40** (`#97 chan_op`) and **cyrius 6.5.8**
(the `sys_chan_*` peer).

⛔ **The TCP arm is DELETED on agnos, not gated.** agnos `planning/ipc.md` §9.6 is explicit that a plan
which preserves the old path "has not done the job"; revertibility comes from bite ORDER — bites 0-5
landed no consumer — not from keeping a rejected transport compiled in. **Linux keeps its own
transport, and that is not a fallback: Linux is a different target.**

**What went with it, and why none of it is a loss:** `sock_connect #47` holding preempt disabled for
the whole attempt and starving the compositor being dialled · the retry loop that could not be added
because of it (200 tries stretched a 30 s budget to 72 s with zero connections) · the ~2 KB loopback
window · a **DHCP dependency in a local display protocol** · and the `net_ip` source semantics that made
`net_src_for` necessary. Six accommodations around one choice — which is what falsified it (§10.0).
⚠ `net_src_for` itself **stays**: route-derived source selection is correct for the *network* (§10.4).

### Changed — records, not streams

`setu_write_all` on agnos is a single `chan_send`. ⛔ There is no partial send to loop over — framing is
a property of the CHANNEL, fixed at mint — so a frame over 64 B is now an **error** rather than
something to split. Splitting would reintroduce in userland exactly the message-boundary problem the
band was chosen to remove.

### Fixed — WOULD_BLOCK is finally a distinct, immediate answer

`setu_read_blk` on agnos calls `chan_recv`. The old `sys_read` path routed a tagged socket fd through
the stdlib's `_agnos_sock_recv_block`, which polled under a **30 second** deadline and returned 0 for
**both** EOF and timeout — so `r == 0` could never mean "would-block", and this function's retry loop
multiplied a ~30 s call. `chan_recv` answers immediately and says *which*: `-CH_E_WOULDBLOCK` nothing
yet, `-CH_E_PEERGONE` peer gone. The long-standing note that ring 3 "has no way to ask whether a byte is
waiting" is obsolete on this path.

### Added — the kernel floor is ENFORCED, not documented

`setu_chan_floor_ok()` calls `CH_CAPS` and refuses unless SEND, RECV **and** region-reachability are all
present. §9.9's last kill criterion: *"If a client silently appears to work on a pre-`#97` kernel instead
of refusing at startup, `CH_CAPS` is not doing its job."* ⛔ An unknown syscall number on agnos falls
through the dispatch chain and the caller reads the fall-through value as data, so "it returned
something" is not evidence the band exists — the caps block is.

### Added — announcement, read not searched

`setu_chan_announced_fd()` reads `AGNOS_CHAN` from the environment the compositor staged at spawn —
Wayland's `WAYLAND_SOCKET` shape, where the parent decides the number and the child never searches.
⛔ **No scan fallback.** Scanning would find a channel this process was not given, and on a kernel where
that succeeds inert-by-construction is broken — the right behaviour is to fail loudly, not paper over it.

⚠ **Not yet runtime-proven end to end.** Nothing sets `AGNOS_CHAN` yet — that is bite 7, where
aethersafha mints, endows and spawns clients placed. This bite is verified as: builds `--agnos`, builds
for Linux unchanged, and the agnos arm contains no socket call.

## ⛔ STANDING RETRACTION 2026-08-03 — TCP-on-loopback was the wrong primitive for the desktop transport

**`SETU_TCP_PORT = 7700` / TCP over loopback is a RETIRED WRONG PREMISE.** It was chosen at 0.3.0
because a TCP stack happened to exist, was never put to the operator, and was then carried for a
month behind a stack of accommodations. Its replacement is the **agnos socket (`anu`)**, designed
in agnos [`docs/development/planning/ipc.md`](https://github.com/MacCracken/agnos/blob/main/docs/development/planning/ipc.md)
§9. The transport code still ships only because `anu` does not exist yet and the migration is a
staged twelve-bite cut (ipc.md §9.6) — **its continued presence is not an endorsement.**

⛔ **AND EVERY agnos "PROOF" OF IT BEFORE 1.56.34 PASSED BY ACCIDENT.** The kernel hook
`AETHERSAFHA_SETU_SELFTEST` assigned `net_ip = 0x7F000001` before launching the compositor. agnos
stamped `net_ip` as the *source* of every outbound segment, so a SYN to `127.0.0.1` was answered to
`net_ip` and `tcp_find_conn` never matched — **except** under the selftest, where the assignment made
`src == dst == 127.0.0.1`. **The compositor↔client handshake could therefore not complete on an
ordinary agnos boot BEFORE `net_src_for` (agnos 1.56.34)** (agnos `kernel/core/net.cyr:183-190`
describes the pre-fix behaviour).

⚠ **AFTER `net_src_for` IT DID CONNECT ON agnos, UN-RIGGED — and that is NOT the reason it is being
replaced.** `net_src_for` (agnos `kernel/core/net.cyr:203-206`) derives an outbound segment's source
from its *destination*, so a loopback SYN goes out `src = dst = 127.0.0.1` and its SYN-ACK matches. On
**2026-08-02**, on agnos 1.56.34+, `agnos/scripts/harness/aethersafha-clients-test.py` reached
**`connected: 2, presented: 2`** — setu's own `present_probe` (staged as `/bin/puka`) and the real
dhancha `crab` both connected and presented. That harness is honest by construction: it byte-scans
`build/agnos` and **hard-exits if the kernel carries any selftest hook** (a kernel carrying one does
not fail the test, it *invalidates* it), and it attaches a virtio NIC so DHCP yields a real `net_ip`.
**It is the harness that caught the rigging**, so its green is evidence. ⚠ Scope it exactly: that run
was **QEMU at `-smp 1`**; it was never shown on iron, and `-smp 4` fault-kills.

⭐ **So the ruling is architectural, not empirical.** The transport is retired for being the **wrong
primitive** — a local display protocol has nothing to route, checksum, window, or retransmit and no
business owning a port — **not** for being broken. Those two justify different futures, and the
operator's ruling is the first. Do not restate this retraction as "it never worked on agnos."

**Therefore: every claim in the entries below that a setu client connected to the compositor ON agnos,
dated before [0.7.2] (2026-08-02), is a FALSE GREEN and must not be cited as proof of anything.** The
individually-marked sites are the explicit ones; this rule covers the rest. Entries are preserved
rather than deleted because the audit trail of the mistake is the point — read them as a record of a
wrong path, not as achievements.

⚠ **What is NOT retracted:** the setu **codec / message ABI** (pure, host-tested, transport-agnostic,
survives the transport change untouched), the **shared-buffer present path** (`sys_shm`, which is
exactly the workload leaving the wire), and setu's **Linux arm** (a different target, not an agnos
fallback). ⛔ If the Linux TCP arm ever becomes reachable *on agnos*, that is the wrong path returning.

---

## [0.7.4] - 2026-08-03

### Fixed — the 0.7.3 retraction over-reached and said something false

0.7.3 retired the TCP-on-loopback transport correctly, but its retraction text over-corrected into
**"it never worked on agnos"** — in `src/client.cyr`, `README.md`, and this file's standing retraction
block. That claim is false, and because `dist/setu.cyr` ships to consumers it propagated byte-identically
into five materialized `lib/setu.cyr` copies (aethersafha, crab, dhancha, jalwa, puka) and two
hand-vendored ones (cyrius-doom, cyrius-mine-cart). Two consumer READMEs ended up denying a result their
own binaries produced.

**The corrected, scoped statement, now used everywhere:**

- **Before `net_src_for` (agnos 1.56.34)** the compositor↔client handshake could not complete on an
  ordinary boot. Every green from that era came off the `AETHERSAFHA_SETU_SELFTEST` kernel hook's
  `net_ip = 0x7F000001` assignment and **remains retracted**.
- **After `net_src_for` it did connect, un-rigged.** `agnos/scripts/harness/aethersafha-clients-test.py`
  reached `connected: 2, presented: 2` on 2026-08-02 — setu's `present_probe` and dhancha's `crab`. That
  harness byte-scans the kernel and hard-exits if it carries any selftest hook, and attaches a virtio NIC
  so DHCP yields a real `net_ip`; it is what caught the rigging. Scope: **QEMU at `-smp 1`**, never shown
  on iron, `-smp 4` fault-kills, and "presented" is the compositor's serial claim, not framebuffer evidence.
- **The transport is retired as the WRONG PRIMITIVE for local display IPC, not because it was broken.**
  Replacement is the agnos socket (`anu`), agnos `docs/development/planning/ipc.md` §9; removal
  inventory §10.

Why the distinction is load-bearing: "retired because it was the wrong primitive" and "retired because it
was broken" justify different futures, and only the first survives someone later getting TCP to work.
Erasing the one un-rigged result destroys the evidence that the retirement was right for the right reason.

Changed: `src/client.cyr` (transport banner), `README.md`, this file's standing retraction block, and
`dist/setu.cyr` regenerated from source. **No code change** — comments, docs and the regenerated bundle
only. The transport implementation, the codec/message ABI, and setu's Linux arm are all untouched.

## [0.7.3] - 2026-08-02

### Changed — the connect workaround is reverted; the fix belongs to (and is now in) the kernel

0.7.2 made `setu_connect` dial `sys_net_ip()` because a loopback SYN's reply came back on a 4-tuple the
client's own conn could not match. That was a userland workaround for a kernel behaviour, and the kernel
has since fixed it properly: **agnos `net_src_for`** (`kernel/core/net.cyr:203-206`) derives an outbound
segment's source from its **destination**, so a loopback SYN goes out `src = dst = 127.0.0.1` and its
SYN-ACK matches.

`setu_connect` therefore dials `0x7F000001` again.

> ⛔ **RETRACTED 2026-08-03** — this entry originally ended *"which is what a local display protocol
> should have been doing all along."* **That is exactly backwards.** A local display protocol should
> not have been dialling an IP address *at all*. `net_src_for` is a **receipt of the wrong premise**,
> not a vindication of it: route-derived source selection is a networking concept that had to be added
> to the kernel so a **local** channel could reach **itself**. It is listed in agnos
> [`planning/ipc.md`](https://github.com/MacCracken/agnos/blob/main/docs/development/planning/ipc.md)
> §10.0 among the six accommodations that together falsify the choice. ⚠ `net_src_for` itself **stays**
> (§10.4) — it is correct for the network. What is retracted is the claim that dialling loopback was
> ever the right shape for a desktop transport. The replacement is the agnos socket (`anu`, §9).

⚠ **This raises the kernel floor: agnos >= 1.56.34.** On an older kernel a client built from this
release cannot connect at all. The requirement is stated at the call site; `net_src_for` is documented in
agnos's 1.56.34 section, added there retroactively at that cycle's close because it had shipped with no
entry under any version — which is why setu's own comments briefly cited 1.56.34 and 1.56.35
inconsistently. They now agree.

⭐ 0.7.2's entry below is **not** wrong and is left as written: it accurately documents the tag that
shipped and the reasoning that was correct at the time. This release supersedes it; it does not correct it.

### Fixed — three comments that described the opposite of what the code does on agnos

No control flow changed. These were **contract lies**, and the contract is what callers build on.

⛔ **`setu_read_blk`'s retry budget is not what it looks like.** Its old comment claimed
`0 = would-block → yield + bounded retry` with a *"~10s cap at 5000*2ms"*. On agnos a **tagged** socket
fd's `sys_read` does not reach the kernel directly — the cyrius stdlib routes it to
`_agnos_sock_recv_block` (`syscalls_x86_64_agnos.cyr:1084`), which polls `sock_recv #49` under a **30 s
wall-clock deadline** (`AGNOS_SOCK_RECV_TIMEOUT_S = 30`) plus a 6000-spin backstop, and returns **0 for
both EOF and timeout**. So `r == 0` never means "try again in 2 ms"; it means up to 30 seconds are
already gone. The outer loop then multiplies that by up to 5001 iterations, and the 2 ms sleep between
them is noise against it.

⛔ **`setu_poll_input` is documented "NON-BLOCKING … never stalls" and its body is a `sys_read`** — the
same 30 s wrapper. `setu_client_poll_input`, which every client's frame loop calls, inherits it.

⚠ **Deliberately not "fixed" here.** The working desktop path runs through these functions today and
measures ~10 ms/frame in QEMU, so data is pending on the polls that matter — this is a latent hazard,
not an observed stall. More to the point, ring 3 has **no way to ask "is a byte waiting?" and get an
immediate answer**, so no change confined to this file can honestly provide non-blocking semantics. It
is a kernel/stdlib gap, filed as an agnos 1.56.35 item, and the fix wants a measurement before a design.
The call sites now say so, so the next reader does not "tighten" a retry count that was never the budget
that mattered.

### Verified

Both targets build for all four programs (`present_probe`, `smoke`, `codec_test`, `client_test`); the
two RUN-tests pass — `codec_test: PASS (roundtrip all kinds + reject short/bad-argc/unknown)` and
`client_test: PASS (port + create-surface round-trip + reassembly + buf lifecycle)`. `dist/setu.cyr`
regenerated at v0.7.3 (1133 lines) — consumers read the bundle, not `src/`, so a src-only change would
not have reached crab or puka.

## [0.7.2] - 2026-08-02

### Fixed — ⛔ CLIENTS COULD NEVER CONNECT ON A REAL agnos BOOT: connect to `net_ip`, not 127.0.0.1

`setu_connect` dialled `INADDR_LOOPBACK` (127.0.0.1). agnos puts **`net_ip`** — the host's own IPv4 —
in an outbound SYN's *source* field, and its TCP stack matches a reply on the full 4-tuple. So:

1. Client SYN goes out `src = net_ip`, `dst = 127.0.0.1`. `net_is_loopback` accepts the dst, so the
   segment is delivered through the kernel's lo_ring — this part always worked.
2. The passive open records the peer as `net_ip` and sends its SYN-ACK back with `src = net_ip`.
3. The client's conn was created with `dst_ip = 127.0.0.1`, so `tcp_find_conn(..., src_ip = net_ip)`
   finds **no match**. The reply lands on an unknown 4-tuple and the conn dies.

`sock_connect` #47 returns **-1 instantly** — not the ~8 s SYN-ACK timeout, because the client's own
slot is zeroed — and every client reported the same opaque `setu connect failed`.

⛔ **THE agnos SELFTEST HOOK HID THIS FOR THE WHOLE LIFE OF THE FEATURE.**
`AETHERSAFHA_SETU_SELFTEST` assigned `net_ip = 0x7F000001` in the kernel before it launched the
compositor. That made `src == dst == 127.0.0.1`, the 4-tuple matched, and `aethersafha-setu-smoke.sh`
passed. **No ordinary boot had that fixup**, so the smoke was green while the real launch path had
never once worked.

> ⛔ **RETRACTED / RESTATED 2026-08-03 — READ THIS AS A FALSE GREEN, NOT AS A MECHANISM.** The
> paragraph above described the rig neutrally, as though it were a quirk that a fix then cleared.
> It is not. **`aethersafha-setu-smoke.sh` was never a passing test — it was a test that could not
> fail**, because the kernel it ran under had been edited to make the one condition under test true.
> Every "GATE 4 GREEN", every "green on agnos", every "proven on the sovereign target" claim anywhere
> in this ecosystem that traces to that smoke is **manufactured**, and citing one is how the wrong
> premise gets resurrected.
> The hook, its `build.sh` define, and the smoke itself have been **DELETED** (2026-08-03) —
> scaffolding that manufactures a false pass has no historical value; it is the trap. What survives is
> this record that it existed. See agnos `kernel/core/net.cyr:183-190` and
> [`planning/ipc.md`](https://github.com/MacCracken/agnos/blob/main/docs/development/planning/ipc.md)
> §10.1.
⚠ The kernel's *other* loopback proof (`loopback-smoke.sh`, 5/5) connects to **net_ip** and never to
127.0.0.1 — two green proofs disagreeing about the address, and the bug lived in the gap.

**Fix:** dial `sys_net_ip()`, falling back to 127.0.0.1 only when it is 0.
⚠ `net_ip == 0` (no NIC ⇒ no DHCP) is **not** fixable from ring 3 — the reply's dst would be 0, which
`net_is_loopback` explicitly excludes — so that case is left unchanged rather than newly broken, and
belongs to the kernel.

### Added — `setu_connect_error()` / `setu_connect_rc()`

`setu_client_connect` returns 0 for both a failed socket and a failed connect, so every client
printed one indistinguishable message for two different faults. These expose the failing **stage**
(-2 socket / -3 connect) and the **raw kernel return** behind it. On agnos the connect now calls
`sys_sock_connect` directly so that return survives instead of being flattened to `Err(1)`.

⚠ **DO NOT ADD A CONNECT RETRY LOOP** — tried, and strictly worse. `sock_connect` #47 holds preempt
DISABLED for the whole attempt, so a retrying client starves the compositor it is waiting for: 200
tries stretched the compositor's 30 s budget to 72 s with still zero connections. A `sched_yield`
between attempts does not help; the cost is *inside* the blocking syscall. The reason is recorded at
the call site so it is not re-attempted.

### Verified

`aethersafha` launched **in the foreground** from the agnsh prompt in QEMU: both clients connect and
present, confirmed on the **framebuffer** (not the serial log) — the slim `present_probe` and crab's
dual-pane file manager, composited as windows.

> ⚠ **Qualified 2026-08-03.** This observation is **honest** — it used no selftest hook, and it is the
> first and only time a setu client is known to have connected to the compositor on agnos without a
> rigged kernel. It is retained for exactly that reason. ⛔ But it does **not** make TCP-on-loopback a
> correct desktop transport, and it must not be cited as one: it is the measurement that finally showed
> what the previous month of "greens" had been hiding. The transport is retired in favour of the agnos
> socket (`anu`); see the STANDING RETRACTION at the top of this file.

## [0.7.1] - 2026-08-02

### Changed — cyrius pin 6.4.71 -> 6.5.5

Toolchain catch-up across the whole desktop stack, cut together so the next burn runs binaries built
by ONE compiler rather than 6 different ones.

⚠ **The pin was documentation, not enforcement.** `cyrius build` compiles with the INSTALLED `cycc`,
prints a `toolchain drift` warning, and carries on — so this project was already being built by 6.5.5
before this bump. Verify provenance with `~/.cyrius/versions/<pin>/bin/cyrius` when it matters.

⭐ What the gap actually contained, for a reader deciding whether to care:
- **6.5.1** made overload-suffix arity a hard **error** where it used to warn. Latent arity
  mismatches are now build failures instead of silently-wrong code — good, and the reason this
  sweep surfaced real defects elsewhere in the stack.
- **6.4.75** fixed `fn_table` growth past 8192 silently corrupting six fn-indexed side tables.
- **6.5.0** added file-scoped `private` / per-item `public` — the first real answer to this
  ecosystem's duplicate-`fn`-silently-shadows hazard.
- **6.4.82** completed the agnos GPU syscall wrapper band to `#82`-`#95`, so `sys_gpu_shader_op`
  (#92) and `sys_gpu_modeset_op` (#93) no longer need a raw `syscall()` behind an `#ifdef`.

### Verification

Host + `--agnos` builds green; `client_test` + `codec_test` pass; `distlib` regenerated.

## [0.7.0] - 2026-07-23

### Added — `SETU_SURF_PREMULTIPLIED` (surface flag bit 1) + `setu_client_request_premultiplied`

A client can now declare that its surface pixels are **premultiplied BGRA** (`c <= a`), which lets the
compositor blend it per-pixel instead of copying it opaquely. Wire-compatible and additive: the flags word
already existed (`SETU_SURF_FULL_KEYS` is bit 0), so existing clients send 0 or 1 and are unaffected.

⚠ **Opt-in, and it must stay that way.** On agnos the compositor composites an unflagged surface with
`gpu_blit_shm` **#87** — an opaque copy that ignores byte 3 — and a flagged one with `gpu_shader_op` **#92**
op 0x01, premultiplied src-over, which **reads** byte 3. A surface whose alpha byte is 0 (exactly what a
bare `0x00RRGGBB` colour produces, and what several painters in the stack emitted until this week) renders
**wrong** under #92. Defaulting this on would break every existing client.

> ⛔ **Corrected 2026-08-02** — this entry originally said such a surface becomes *"fully transparent under
> #92: the window vanishes."* That is wrong. The kernel shader is `out = src + dst*(1 - src_a)`, so alpha 0
> gives `out = src + dst` — an **additive over-bright ghost**, not a disappearance. It is nearly invisible
> over the near-black desktop void and blows out over bright chrome, which makes it *harder* to spot than a
> missing window. The opt-in rule above stands unchanged; only the predicted symptom was wrong.

⚠ **Premultiplied means each channel is already scaled by alpha.** Passing straight alpha does **not** error
anywhere in the stack — it renders washed out, silently, with no diagnostic. `sadish`'s `sd_premul()` is the
sanctioned producer.

### Notes

Host + `--agnos` builds green; `client_test` + `codec_test` pass; `distlib` regenerated.

## [0.6.0] - 2026-07-23

### Changed — client buffers are now GPU-VISIBLE on agnos, which unblocks the entire hardware-compositing band

`setu_buf_create` asks for **`shm_create_gpu` #86** first and falls back to `shm_create` #71.

⚠ **This one line is why the agnos ring-3 GPU band had no caller.** `#71` allocates **system RAM**, and on
agnos the GPU cannot reach system RAM at all — bus-master is off by design and the engines see only the
framebuffer aperture. So a `#71` slot is structurally un-blittable, and the kernel rejects it at **both** GPU
entry points: `gpu_blit_shm` #87 with `src_mc == 0 ⇒ the GPU cannot read it`, and `gpu_shader_op` #92 with
`GPO_E_BADSLOT`. Every client surface in the desktop was allocated this way, so ~15 iron burns of proven GPU
capability (`#84`-`#89`, `#92`) had **zero** reachable consumers.

The published diagnosis was that alpha was the blocker (sadish forcing `0xFF`, bhumi packing `X=0`). That is
real but **downstream** — it gates `#92`'s premultiplied blend specifically. It was not what stopped `#87`,
which is an opaque blit and needs no alpha convention at all.

`#86` is the GPU-visible **peer** of `#71`: same slot table, same `#72`/`#73`/`#74` afterwards, only the
backing memory differs. Callers are unaffected and cannot tell which they got.

**The fallback is the QEMU path, not defensive padding.** `#86` returns `-1` when there is no GPU carveout,
which is every QEMU boot — the desktop keeps working there on the CPU copy path.

### Changed — cyrius pin 6.4.34 → 6.4.71

Required: `sys_shm_create_gpu` landed in the 6.4.7x wrapper set. Also picks up the `net.cyr` `sock_accept`
per-poll allocation-leak fix that accept-loop consumers want.

### Notes

Host + `--agnos` builds green; `client_test` and `codec_test` pass; `cyrius lint` 0 warnings, `fmt --check`
clean, `vet` clean, `distlib` regenerated (no drift).

⚠ **Consumers of this release get GPU-visible buffers automatically** — no API change, no call-site change.
What they do NOT get for free is a GPU *consumer*: `aethersafha`'s per-pixel composite loop still runs on
the CPU until it is wired to `#87`.


## [0.5.1] — 2026-07-12 — present-buffer reuse (shm-slot/tmpfs leak fix) + input stream reassembly

Two client-transport defects found by cyrius-doom's 0.33.3 audit round (doom is the first
35 Hz continuous-present consumer; probe/nav clients present rarely enough that neither bit).

### Fixed

- **`setu_client_present` allocated a NEW shared buffer every present and never freed any**
  (`setu_buf_create` per call; `setu_buf_close` had zero callers; `SetuClient` had no field
  to cache an id). On agnos this exhausted the kernel's **16 system-wide shm slots** in
  under half a second of 35 Hz presents — every later present (doom's *and every other setu
  app's*) fell to the inline-TCP path, which is exactly the 2 KB-loopback-window stall the
  shared buffer exists to avoid, and the slots were unreclaimable until reboot. On Linux it
  leaked one `/dev/shm/setu-buf-*` tmpfs file per frame (~9 MB/s at 35 Hz). Now the client
  caches ONE buffer id (`SETU_C_BUFID`/`SETU_C_BUFSZ`), rewrites it in place each present
  (the compositor re-reads the attached id per commit, so in-place rewrite is the designed
  path), recreates it on resize, drops it on a failed write (no dead-id retry loop), and
  **`setu_client_close` frees it**. RUN-tested: tmpfs create → write → read-back → close →
  read fails (buffer really destroyed).

### Added

- **`setu_client_poll_input(c, msg_out)` — non-blocking input poll with STREAM REASSEMBLY.**
  The bare `setu_poll_input` decodes only the FIRST frame of each recv and drops any
  coalesced or split tail — TCP has no message boundaries, so a fast key sequence lost
  events, and a lost key-RELEASE is a stuck key for `SETU_SURF_FULL_KEYS` consumers (doom:
  the player walks forever). The client now carries a 512-byte reassembly buffer
  (`SETU_C_INBUF`/`SETU_C_INLEN`, lazily allocated once — no per-poll allocation, which also
  removes the old per-call 256 B bump-alloc leak for consumers on never-free allocators);
  frames are handed out one per call, partial frames complete on a later poll, and a
  desynced header resets the buffer (the stream has no resync marker). `setu_poll_input`
  is kept for API compat with a caveat comment. RUN-tested: two coalesced INPUT_KEY frames
  + a half frame in one buffer → both delivered, the release survives, the split frame
  completes when its tail arrives.
- `SetuClient` grows from 24 to 56 bytes (`SETU_C_BUFID`/`SETU_C_BUFSZ`/`SETU_C_INBUF`/
  `SETU_C_INLEN`). The struct is opaque (allocated by `setu_client_connect`), so consumers
  recompile against the new dist with zero code changes; the wire is untouched.

## [0.5.0] — 2026-07-10 — full key events (press + release) for held-key apps

Games and apps that need **held-key state** (hold W to keep moving) can now opt into full
keyboard events. A client calls `setu_client_request_keys(c)` before its first present; the
flag rides the existing `CREATE_SURFACE` `flags` word (arg2, `SETU_SURF_FULL_KEYS = 1`), so the
compositor delivers `SETU_INPUT_KEY` on **both press and release** with the make/break in the
`mods` arg (1 = press, 0 = release). **Wire-compatible and opt-in:** the message shape is
unchanged (argc stays 3), and a client that never requests full keys keeps the press-only
stream with `mods = 0` — byte-identical to 0.4.0, so nav clients (crab, present_probe, jalwa)
need no change. First consumer: cyrius-doom's `PM_SETU` backend (real held movement on the
aethersafha desktop); the compositor honours the flag per-surface (aethersafha).

### Added

- `setu_client_request_keys(c)` (client API) + `SETU_SURF_FULL_KEYS` surface-flags constant.
- `SetuClient` gains a `SETU_C_FLAGS` field carrying the requested `CREATE_SURFACE` flags into
  the lazy first-present handshake.

## [0.4.0] — 2026-07-09 — INPUT + FOCUS over setu ~~proven end-to-end on the sovereign kernel~~

> ⛔ **RETRACTED 2026-08-03 — "proven end-to-end on the sovereign kernel" IS A FALSE GREEN.** Every
> agnos-side proof in this entry required a compositor↔client TCP connection, and on this date **no such
> connection could complete on an ordinary agnos boot** — the SYN-ACK came back addressed to `net_ip`
> and `tcp_find_conn` never matched (that defect was not even *found* until [0.7.2], 2026-08-02, three
> weeks later). These harnesses ran against a kernel built with `AETHERSAFHA_SETU_SELFTEST`, which
> assigned `net_ip = 0x7F000001` and made the mismatch vanish. **The input and focus behaviour was
> demonstrated only under a rigged kernel; it was never proven on the sovereign target.** The version
> tag and its API additions stand — the *proof* does not. See the STANDING RETRACTION at the top of
> this file and agnos [`planning/ipc.md`](https://github.com/MacCracken/agnos/blob/main/docs/development/planning/ipc.md)
> §10.1.

The input milestone. setu's S→C input channel — non-blocking poll (0.3.2), keys, and now
**focus** — is ~~demonstrated end-to-end on agnos~~ (⛔ false green, see above — demonstrated only
under a rigged kernel): the reference client `present_probe` runs as
a multi-window desktop where the compositor (aethersafha) routes keystrokes to the focused
window and moves focus on TAB, and each client renders its own state from the wire.
Minor bump to mark the milestone — the **library API is unchanged since 0.3.2** (`setu_poll_input`
+ the `SETU_INPUT_*` constructors/argc table were already in place); the delta is the reference
client and the proof.

### Added

- **`present_probe` renders `SETU_INPUT_FOCUS`** — tracks the focus flag off the wire and draws
  its border BRIGHT green (focused) vs DIM green (unfocused), so focus is legible on the client
  itself as it moves (e.g. on TAB), not only as a compositor-side titlebar tint. Combined with
  the existing `SETU_INPUT_KEY` reaction (bar flashes white), the client now demonstrates the
  full S→C input surface.

### ⛔ ~~Proven (on agnos, QEMU USB-xHCI keyboard `sendkey`)~~ — RETRACTED 2026-08-03, ALL THREE ARE FALSE GREENS

> ⛔ **None of the three below proved anything about agnos.** Each needed a live client↔compositor
> setu connection, which on an ordinary boot of this era **could not be established at all**; they ran
> against `AETHERSAFHA_SETU_SELFTEST` kernels whose `net_ip = 0x7F000001` fixup made the 4-tuple match
> by accident. `aethersafha-setu-smoke.sh` has since been **deleted**. Recorded verbatim as the
> falsified claim, **not** as evidence:

- ~~**Keyboard routed to the focused window**~~ — injecting a key flips only the focused client
  (white bar), the unfocused client untouched (`setu-input-test.py`). ⛔ FALSE GREEN — rigged kernel.
- ~~**Focus cycles over setu**~~ — TAB moves the bright (focused) border cleanly from one client to
  the other; focus is client-rendered, driven by `SETU_INPUT_FOCUS` (`setu-focus-test.py`).
  ⛔ FALSE GREEN — rigged kernel.
- ~~**Multi-window**~~ — two clients composited as distinct cascaded windows, each live-animating
  its own shared buffer (`aethersafha-setu-smoke.sh`). ⛔ FALSE GREEN — this is the selftest smoke
  itself, the single test the whole corruption rests on. Deleted 2026-08-03.

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
  the focused window. ~~Validated on agnos by an injection harness (`setu-input-test.py`) that
  boots with a QEMU USB-xHCI keyboard and drives `sendkey`.~~
  > ⛔ **RETRACTED 2026-08-03 — "validated on agnos" IS A FALSE GREEN.** The harness booted an
  > `AETHERSAFHA_SETU_SELFTEST` kernel, whose `net_ip = 0x7F000001` assignment is the only reason the
  > client could connect at all; an ordinary agnos boot of this era could not complete the handshake.
  > The `setu_poll_input` API addition above stands; the agnos validation does not.

## [0.3.1] — 2026-07-09 — SHARED-BUFFER present (out-of-band pixels) + the on-device tagged-fd read/write fix

The present path stops streaming pixels inline over the socket and hands them to the
compositor through a **shared buffer** referenced by id. On agnos this is what makes a
real surface composite: a hundreds-of-KB inline pixel payload can't drain through the 2 KB
`TCP_RX_RING` while the single-CPU sender holds preemption in `sock_send`#48 — it deadlocks.
Shared-buffer sidesteps it (and is lower-copy). The `setu_serve_probe`+`present_probe`
round-trip is proven on Linux, and ~~`aethersafha-setu-smoke.sh` is **green on the sovereign
kernel**~~. Cyrius pin **6.4.25 → 6.4.34** (for the native `sys_shm_*` wrappers).

> ⛔ **RETRACTED 2026-08-03 — "green on the sovereign kernel" IS A FALSE GREEN.**
> `aethersafha-setu-smoke.sh` ran against a kernel built with `AETHERSAFHA_SETU_SELFTEST`, which
> assigned `net_ip = 0x7F000001` so that `src == dst == 127.0.0.1` and the 4-tuple matched. Without
> that edit the compositor↔client handshake could not complete on any ordinary boot. The smoke has been
> **deleted**. ⚠ The **Linux** round-trip in the same sentence was real, and the shared-buffer path
> itself is real and survives — but note what this entry is actually reporting: **the pixels left the
> wire because the wire could not carry them.** That was the workload voting against the transport, and
> it was read backwards at the time ("keep the small control channel on TCP") when it meant *TCP is the
> wrong primitive*. PCM did the same thing independently a few weeks later. See agnos
> [`planning/ipc.md`](https://github.com/MacCracken/agnos/blob/main/docs/development/planning/ipc.md)
> §10.0.

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
  is a plain `write`, so it stays portable). ~~This is what let the on-device present complete.~~
  > ⛔ **RETRACTED 2026-08-03** — the on-device present completed only under an
  > `AETHERSAFHA_SETU_SELFTEST` kernel; an ordinary agnos boot could not get a connection to write on
  > in the first place. The tagged-fd defect described above was **real** and the fix was correct — but
  > it was not the last thing standing between this transport and a working desktop, and this sentence
  > must not be read as saying it was.

## [0.3.0] — 2026-07-08

> ⛔ **THIS IS THE ENTRY THAT INTRODUCED THE WRONG PREMISE. RETRACTED 2026-08-03.**
> Choosing **TCP over loopback** as the AGNOS desktop transport was wrong, and it was wrong on the day
> it was written — not merely superseded later. It was picked because a TCP stack happened to exist,
> labelled a stopgap, **never put to the operator**, and then defended for a month by six
> accommodations (`net_src_for` · the no-connect-retry rule · sub-window chunking · a boot-path DHCP
> wait before a display handshake · `SO_REUSEADDR` on the audio port · a selftest that made the only
> passing test pass by accident) plus an advisory `path` argument that six consumers carried, ignored
> and passed identically. A local display protocol has nothing to route, nothing to checksum, no window
> to negotiate, no RTO to wait out, and **no business owning a port**.
> ⛔ **And the claim below — "so the sovereign desktop runs on the sovereign kernel" — was never true.**
> On an ordinary agnos boot the compositor↔client handshake could not complete at all, from this
> release until [0.7.2] (2026-08-02). Every agnos "green" in that window came from an
> `AETHERSAFHA_SETU_SELFTEST` kernel. The end-to-end `puka` ↔ `aethersafha` PPM proof cited here was a
> **Linux host** result.
> ⭐ The replacement is the **agnos socket (`anu`)** — agnos
> [`planning/ipc.md`](https://github.com/MacCracken/agnos/blob/main/docs/development/planning/ipc.md)
> §9. The transport code below still ships **only** because `anu` does not exist yet and its
> migration is a staged twelve-bite cut (§9.6); removing it today would leave the desktop with no
> transport at all. ⚠ setu's **Linux arm stays** — Linux is a different target, not an agnos fallback.

The reference transport goes **cross-platform** (item 3b of the road-to-desktop):
setu now speaks **TCP over loopback** (`127.0.0.1 : 7700`) on Linux **and** on
agnos, ~~so the sovereign desktop runs on the sovereign kernel — not just the host~~.
This **replaces** the 0.2.0 AF_UNIX client, which was Linux-only and fail-closed
on agnos. Proven end-to-end (**on the Linux host**): `puka` (client) connects over TCP and presents a
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
