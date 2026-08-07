# `setu_read_msg` reads a header then a body — which cannot work on a record transport

**Status:** ✅ **FIXED — shipped in setu 0.8.2 (2026-08-07); Linux regression from the same change
repaired in 0.8.3.** Filed 2026-08-06.
⚠ The 0.8.2 fix added a wall-clock deadline that read `sys_uptime_ms` — an **agnos-only** symbol —
outside its `#ifdef`, breaking every Linux consumer. setu's own gates missed it because `smoke.cyr`
calls nothing, so DCE demoted the undefined function to a warning. 0.8.3 moves the read inside the arm
and adds `programs/reach_test.cyr` (forces the transport surface reachable) plus an `--agnos` CI build.
⭐ `setu_read_msg`'s agnos arm is now one `setu_read_blk` + `setu_decode` (one record == one message);
`setu_read_blk`'s `sys_sleep_ms` retry is gone, replaced by a preemptible spin under a `sys_uptime_ms()`
deadline. **agnos 1.56.40 bite 7 is proven on top of it**: two clients (`present_probe` + `crab`) both
present under QEMU `-smp 4` — `presented: 2`, framebuffer-confirmed.
⚠ **Consumers repin to `0.8.2`.** `crab` and `aethersafha` carry a TEMP `path = "../setu"` override in
`cyrius.cyml` until the tag exists; both revert to `tag = "0.8.2"` the moment it does.
**Affects:** setu 0.8.0, 0.8.1 (the channel-band cutover) on agnos only. Linux is unaffected.
**Severity:** High — every setu handshake fails on agnos. The client connects, sends, and the
compositor cannot read what it sent.

## What happens

`setu_read_msg` (`src/client.cyr:360`) is length-from-header framing:

```cyrius
if (setu_read_exact(fd, buf, 16) < 0) { return 0 - 6; }   # header
var total = (2 + argc) * 8;
if (total > 16) { setu_read_exact(fd, buf + 16, total - 16); }   # body
```

That is correct for a STREAM. On the channel band **one record is one message, delivered
all-or-nothing** — so the 16-byte header read is asking for a prefix of a record, and the body it then
asks for does not exist as a separate thing. The message is gone after the first read.

## Why it stayed invisible

The agnos kernel's `CH_RECV` **silently truncated** a record that did not fit the caller's buffer, and
advanced the cursor past the remainder. So the header read returned 16 plausible bytes, consumed the
whole message, and the body read then blocked until it timed out — surfacing as an unexplained
handshake failure inside **aethersafha**, two layers and one repo away from the cause.

⭐ **The kernel half is fixed** (agnos 1.56.40): a record that does not fit now returns `-CH_E_ARG` and
**stays queued**, with a selftest asserting both the refusal and that a subsequent full-size read still
gets the whole record. That converts this from a silent corruption into a loud, local error — but it
does not make setu's read path correct, it just stops it lying.

## The fix

On agnos, `setu_read_msg` should be **one `chan_recv` of the whole record**, then decode from it —
no header/body split, no `setu_read_exact`. The record length the kernel returns IS the frame length.

⚠ `setu_read_exact` itself has no meaning on a record channel and should be Linux-only, not adapted:
"read exactly N bytes" is a stream concept, and a record transport that emulates it re-imports the
message-boundary problem the band was chosen to delete.

⚠ Check `setu_srv_read_msg` / `setu_srv_read_exact` on the compositor side for the same shape.

## Evidence

agnos `aethersafha-clients-test.py`, `AE_CLIENTS_MODE=bg`: `launched: True, placed: 2, presented: 0`,
with the compositor reporting "channel read failed" per client. A diagnostic probe on the compositor's
own end immediately after spawn reported **"a record was already waiting"** — proving the client had
connected and sent, and that the transport was working end to end. The failure is entirely in how the
bytes are re-read above it.
