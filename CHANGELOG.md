# Changelog

All notable changes to **setu** are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and this project adheres
to [Semantic Versioning](https://semver.org/).

---

## [0.8.13] - 2026-10-10

### Fixed — on Linux a compositor opened whatever name a client's buffer id gave it, and could be held there

A client chooses its buffer id and sends it in `ATTACH` (arg5), and on Linux `setu_buf_read` opened
`/dev/shm/setu-buf-<id>` with a plain `O_RDONLY`. /dev/shm is world-writable, so any local process can
put something at that name, and the caller is a compositor's frame loop:

- a FIFO held the open until a writer came, which could be never;
- a file whose owner held a write lease (`F_SETLEASE`) held it for lease-break-time, 45 s by default
  (measured: 45,001,102 µs, then the read went ahead);
- a symlink was followed to whatever it named.

aethersafha 0.17.6 works around it with its own reader, `win_client_buf_read`, on its frame loop's
paths. Its probe handshake (`setu_srv_commit_from_create`) still calls `setu_buf_read`.

- **`setu_buf_read` opens with `O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC`**, then `fstat`s the
  descriptor it opened and refuses anything that is not a regular file of at least `size` bytes.
  `O_NONBLOCK` makes the open return at once: a FIFO opens (and the check refuses it), and a leased
  file fails `EWOULDBLOCK`. `O_NOFOLLOW` refuses a symlink (`ELOOP`). The check is on the descriptor,
  not the path, so a rename between a check and the open cannot slip a FIFO in.
- **A regular file reads exactly as before.** `O_NONBLOCK` does not affect `read(2)` on a regular file:
  the page cache answers it, and it never waits for a writer. Only a regular file reaches the read loop.
- ⚠ **A file shorter than `size` is now refused before a byte is copied.** It was refused before too,
  with -1 at EOF, but only after the short file had been copied over the front of `dst`, so a compositor
  reading into its window cache kept a torn frame. `dst` is now left as it was. A file that shrinks
  while it is being read still fails at EOF, after a partial copy.
- Return codes are unchanged: 0, or -1 for every refusal.

### Fixed — a client followed a symlink planted at its next buffer name and truncated what it named

`setu_buf_create` made a predictable name (`pid * 100000 + counter`) with `O_WRONLY | O_CREAT | O_TRUNC`,
without `O_EXCL` or `O_NOFOLLOW`. A symlink planted there was followed: its target was truncated and
pre-sized, and the client's first present wrote pixels into it. That reached any file the client can
write. `setu_buf_write` reopened the name with a plain `O_WRONLY` on every present.

- **`setu_buf_create` creates with `O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC`**, mode 0600
  as before. `O_EXCL` fails `EEXIST` on anything already at the name: a file, a directory, a FIFO, or a
  symlink, dangling or not (under `O_EXCL` the kernel never follows a final symlink). On `EEXIST` it takes
  the next counter value, for at most `SETU_BUF_CREATE_TRIES` (16) names, and then returns -1. A stale
  file left by a crashed process that had our pid is skipped without being opened. Any other open error
  fails at once, as before.
- **`setu_buf_write` opens with `O_WRONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC`** and refuses anything
  that is not a regular file. The name is the client's own, but the client reopens it on every present
  for as long as it runs. If the name is removed and something else is put there, a symlink is refused
  (`ELOOP`), and a FIFO cannot hold the client in open: with no reader the open fails `ENXIO`, and with
  one the regular-file check refuses it. `O_NONBLOCK` does not affect `write(2)` on a regular file.
- Signatures and return codes are unchanged. `setu_buf_close` is unchanged: `unlink` never follows a
  symlink.
- **agnos is unchanged.** Its buffers are kernel shm slots addressed by id (`#86`, `#71` to `#74`),
  with no name to plant anything at. The four agnos arms of `buf.cyr` are the same source as in 0.8.12.

⚠ The flags are the stdlib's `O_*` names, never numbers: `O_NOFOLLOW` is 0x20000 on x86_64 and 0x8000 on
arm64. cyrius 6.6.4 added the names after a hardcoded x86 value reached arm64 as `O_LARGEFILE`. Building
setu therefore needs cyrius 6.6.4 or later. setu pins 6.6.6, and every consumer pins 6.6.6 or later.

RUN-tested in the new `programs/buf_safety_test.cyr`, which plants each case at a buffer name and
times the call. Each of these is -1 at once, measured at 3 to 24 µs here: `setu_buf_read` on a FIFO with
no writer, on a FIFO holding exactly the bytes asked for (none of them consumed), on a symlink to a real
buffer (the buffer itself still reads), and on a write-leased file; `setu_buf_write` on the leased file,
on a symlink, and on a FIFO with and without a reader. Once the lease is released the file reads.
`setu_buf_read` on a dangling symlink, a directory, a file shorter than asked and an empty name is -1
as well. Every refused read leaves `dst` as it was, including a read of exactly one byte more than the
file holds (the size gate's boundary), and the short file still reads at its own size. A
256 KiB buffer, and a plain file setu did not make, read back byte for byte.
`setu_buf_create` skips a symlink at the next name to a file in /tmp, leaving the target and the link
untouched. It skips a stale file without truncating it. It makes a 0600 regular file of the size
asked. With 15 names taken it uses the 16th, and with 16 taken it fails after exactly 16 tries and makes
nothing past them. `setu_buf_write` refuses a symlink (writing nothing through it), a directory, and a
FIFO with no reader or with one (writing nothing into it).

⛔ A regression here is a hang, not a wrong answer, so the suite arms a watchdog like
`read_deadline_test`'s: a child that removes what the suite planted and SIGKILLs it after 30 s, which is
inside the 45 s a lease would hold a blocking open. FIFOs come from `mknodat`, which the pinned stdlib
does not wrap. The suite issues it by its x86_64 number and SKIPs the FIFO checks on other arches.
The leased file is leased by the suite itself, because only a file's owner may lease it, and the suite
ignores the SIGIO that a lease break sends.

**Negative controls: 13 mutants, each killed.** Without `O_NONBLOCK` on the read or on the write, the
FIFO open hangs and the watchdog fails the suite at 30 s. With `O_NONBLOCK` dropped from the read and
only the lease group run, the read waits 45,001,102 µs and then reads. The 0.8.12 read (plain
`O_RDONLY`, no check) also hangs. Without `O_NOFOLLOW` the read returns the linked buffer's bytes, and
the write writes through the link. With no check on the descriptor, the read consumes the FIFO's bytes
and copies a short file over `dst`. Without the regular-file test the write puts its bytes into the
FIFO. Without the size test a short file is copied over `dst`. A create without `O_EXCL` returns -1 on
the symlink (`ELOOP`), and opens the stale file and resizes it. The 0.8.12 create flags truncate the
symlink's target and resize it. A create that does not skip on `EEXIST` fails on the first taken name.
An unbounded create makes a 17th name, and `unix_transport_test` fails too.

### Fixed — setu allocated on every message, poll and present, and never freed it

cyrius's `alloc` is a bump allocator with no `free()`, so an allocation per call is a leak per call.
These calls allocated each time they ran:

| Call | 0.8.12, per call | 0.8.13 | Who runs it, and how often |
|---|---|---|---|
| `setu_send` | 128 B | 0 | every message: a compositor's key, pointer, scroll and focus forwards; every present |
| `setu_recv` | 256 B | 0 | every frame read through it |
| `setu_poll_input` | 256 B | 0 | every poll, **including the common one that finds nothing**: once a frame per client |
| `setu_read_msg_ms` (and `setu_read_msg`, `setu_client_recv`) | 128 B | 0 | every frame read, and every read that times out |
| `setu_client_present`, at a held buffer | 416 B | 0 | every frame a client presents: two constructors (80 B each) and two sends |

A client presenting at 60 Hz grew by about 90 MB an hour, and a compositor grew by 256 B for every
client on every frame it polled them.

- **Each buffer is now function-local.** `var frame[128]` is 128 bytes of the call's own stack frame,
  so it is reentrant and per-thread and is gone at return. Measured on cyrius 6.6.6, a 128-byte local in
  a recursive fn gets distinct storage at each level and keeps its value across the inner calls, and the
  heap does not move. The compiler warns when a local array is over the per-fn frame budget ("gets
  STATIC storage: one buffer shared by all calls and all threads"). No setu build prints that warning.
- **`setu_client_present` builds its ATTACH and then its COMMIT in one function-local `SetuMsg`**,
  through two internal helpers, `setu__attach_buf_into` and `setu__commit_into`, over `setu__msg_init`.
  `setu_attach_buf` and `setu_commit` now call the same helpers, so each message's arg order still has
  one definition. The bytes on the wire are unchanged.
- Signatures, return values and behaviour are unchanged on both targets.
- ⚠ **On agnos the channel calls now get a stack buffer, where they used to get heap memory.** The
  kernel accepts any mapped user range: `chan_queue` and `chan_deliver` check `is_user_range(ubuf, len)`
  and then copy byte by byte. The ring-3 stack is a mapped 2 MB page at 0x3FC00000, inside that window,
  and agnos's own ring-3 validator (`/bin/sysi`) passes a stack scratch buffer to `uname` #34. This is
  built for `--agnos` here but not run, because CI has no agnos host.

What still allocates, and why it stays:

| Site | When | Why |
|---|---|---|
| `setu_msg_new` and every message constructor (`setu_hello` … `setu_input_focus`) | each call, 80 B | Each returns a fresh message by contract, and a caller may hold several at once. A caller that builds a message per event can fill function-local storage with the public setters instead (below). |
| `setu_err_new` | each call, 16 B | Same contract. No setu path calls it; the codec returns negated codes. |
| `setu_connect` / `setu_listen` (Linux `sockaddr_un`, 128 B); `setu_chan_floor_ok` (agnos caps block) | once per connect or listen | one-time |
| `setu_client_connect` (the `SetuClient`, 56 B) | once per connection | it is the handle |
| `setu_client_poll_input` (reassembly buffer, 512 B) | its first poll | one-time, kept in the handle |
| `setu__client_create_surface` (`CREATE_SURFACE` and the reply, 160 B) | the first present, and each retried handshake | one-time; a retry also waits on a read |

RUN-tested in the new `programs/zero_alloc_test.cyr`, whose oracle is the allocator's own count,
`alloc_used()`, read before and after 10,000 calls of each function over a real AF_UNIX /
`SOCK_SEQPACKET` connection. Every call does its real work, and the loop counts that it did. The same
suite, built against the 0.8.12 sources, gives the "before" column:

| 10,000 calls of | 0.8.12 | 0.8.13 |
|---|---|---|
| `setu_send` (an `INPUT_KEY`, then drained) | 1,280,000 B | 0 B |
| `setu_recv` (a `COMMIT` queued) | 2,560,000 B | 0 B |
| `setu_read_msg_ms` (a `COMMIT` queued, bound 1000 ms) | 1,280,000 B | 0 B |
| `setu_read_msg_ms` (nothing queued, bound 0) | 1,280,000 B | 0 B |
| `setu_read_msg` (a `COMMIT` queued) | 1,280,000 B | 0 B |
| `setu_poll_input` (idle) | 2,560,000 B | 0 B |
| `setu_poll_input` (a `COMMIT` queued) | 2,560,000 B | 0 B |
| `setu_client_poll_input` (idle; with an `INPUT_KEY` queued) | 0 B; 0 B | 0 B; 0 B |
| `setu_client_present` (8x8, held buffer: `ATTACH` + `COMMIT` on the wire) | 4,160,000 B | 0 B |
| `setu_buf_write` + `setu_buf_read` (256 B) | 0 B | 0 B |

aethersafha's own `setu_clients` suite counts the same thing from the compositor's side. 200 served
records allocate 51,200 B against 0.8.12 ("setu's 256 B per record") and 0 B against 0.8.13.

**Negative controls: 5 mutants, each killed.** Restoring 0.8.12's `alloc` in `setu_send`,
`setu_recv`, `setu_poll_input` or `setu_read_msg_ms` fails the matching rows, at exactly 128, 256, 256
and 128 B a call; the first also fails the present row at 256 B. Restoring the two constructors in
`setu_client_present` fails it at 160 B a present.

### Changed — `unix_transport_test`'s present steps no longer rely on the create following a symlink

Steps 1 and 5 make a buffer impossible to create. They used to put one directory at the next name, and
the create now skips it, so they occupy all 16 names it may try. Step 7 needs a replacement buffer
whose write fails. It used to put a symlink to `/dev/full` at the next name and rely on the create
following it, which is the defect fixed above. Its pixels are now a `PROT_NONE` page, so the create
succeeds and `write(2)` fails `EFAULT`. Each step checks what it checked before.

### Consumers

Every call of a changed function in aethersafha, crab, dhancha and puka was read. Each consumer was
built in a scratch copy through a live absolute `path` dep, first against 0.8.12 and then against
0.8.13, on its own pinned toolchain, for Linux and `--agnos`. Their repos were not touched.

| Consumer | Calls | Built, tested | Verdict |
|---|---|---|---|
| aethersafha (cyrius 6.6.11) | `setu_buf_read` on agnos (`window.cyr:288`) and in the probe handshake (`setu_dispatch.cyr:122`); its Linux reader `win_client_buf_read` builds the path with `setu_buf_path`. `setu_send` for every forward (`main.cyr:364-380`, `setu_dispatch.cyr:802-825`, `window.cyr:262`, `compositor.cyr:503/544`, `setu_clients.cyr:393`). `setu_poll_input` (`setu_dispatch.cyr:503/754`), `setu_recv` and `setu_read_msg` (`setu_server.cyr:37/55`). Tests use `setu_buf_create` / `write` / `close` and `setu_read_msg_ms`. | `src/main.cyr` for Linux (4,288,568 B, sha256 `7b299baea60c`; 0.8.12 same size, `1537c997d1e2`) and agnos (4,238,264 B, `0c9badd556f9`; 0.8.12 4,238,248 B, `2bf60950bf40`). 22 of 26 builds succeed at both versions (`src/main.cyr` and 12 programs, each for both targets); the same 4 fail at 0.8.12, for reasons outside setu. `cyrius test`: 33 of 33 files pass on both. | Compatible, no change needed. Its serve path drops from 256 B a record to 0, and the probe path's `setu_buf_read` can no longer be held. |
| crab (6.6.6) | `setu_buf_create` once and on resize (`main.cyr:181/512`), `setu_buf_write` every frame (`:316`, `:2331` …), `setu_buf_close` (`:522`), `setu_send` / `setu_read_msg` for the handshake and re-attach (`:317-327`, `:2341-2345`). | `CYRIUS_DCE=1` Linux 612,184 B (`eb64f6b7bc35`; 0.8.12 608,088 B, `c7a8d1cd077a`), agnos 878,392 B (`86d17f6c3e5d`; same size at 0.8.12, `543e7f80123c`). `cyrius test` 2,543 of 2,543 checks and `render_test` 55 of 55 on both. | Compatible. Each frame's write now makes one more syscall (the `fstat`). crab builds setu from a live `path = "../setu"`, so it picks this up at its next local build. |
| dhancha (6.6.6) | forwarders `dh_setu_send` / `recv` / `read_msg` (`src/setu_client.cyr:33-36`), `setu_send` and `setu_recv` (`:44-58`), `setu_client_present` (`:83/94`, `dh_client.cyr:29`), `setu_client_poll_input` (`setu_input.cyr:120`); `programs/setu_widget_client.cyr` uses `setu_buf_create` / `write`, `setu_send`, `setu_read_msg` and `setu_poll_input`. | All 28 programs on both targets, at both versions (e.g. `setu_widget_client` 761,032 B, `f62baaddc61b`; 0.8.12 756,920 B, `1def15049836`). The 20 RUN suites give identical results; `poll_test` exits 3 on both, the three checks the 0.8.11 entry recorded. `distlib` leaves `dist/dhancha.cyr` unchanged. | Compatible, no change needed. |
| puka (6.6.6) | `setu_client_present` (`window_setu.cyr:124`), `setu_client_poll_input` (`:206`); its tests call `setu_send`. | `CYRIUS_DCE=1` Linux 1,505,552 B (`4371054e0daa`; same size at 0.8.12, `ca2bfdbf53f2`), agnos 1,946,424 B (`b9e35a7d6b5a`; 0.8.12 1,946,408 B), `src/test.cyr --agnos`. `cyrius test` 16 of 16 files on both. | Compatible. Its per-frame present drops from 416 B to 0. |

No consumer predicts setu's buffer ids, re-creates a name it expects to truncate, or reaches a buffer
through a link. aethersafha's tests plant their FIFO and symlink at `pid * 100000 + 99001`, far from the
ids `setu_buf_create` makes.

### Found while doing it

- ⚠ **aethersafha's input forwards still allocate 80 B an event**, in the constructor
  (`setu_send(cfd, setu_input_key(…))`); `setu_send`'s own 128 B is gone. A forward can allocate nothing
  by building the message in a function-local `var m[80]` with the public setters
  (`setu_msg_set_kind`, `setu_msg_set_argc(m, setu_kind_argc(kind))`, `setu_msg_set_arg`).
- ⚠ **A client chooses its own id, so it can name another client's buffer.** The ids are predictable,
  and a compositor that can open the file (the files are 0600, so it runs as that client's user, as on a
  normal desktop) would show those pixels in the asker's window. Not changed here: tying a buffer to its
  connection needs the peer's credentials (`SO_PEERCRED`), which only the compositor has.
  `setu_buf_read` takes an id, not a connection.
- `O_CLOEXEC` on the /dev/shm opens has no test. Each descriptor is closed before its call returns, so
  only a concurrent exec could observe the flag.

Every program builds for Linux and `--agnos`. Lint reports 0 warnings, and the three "raw sys_open w/
literal flags" notes on `buf.cyr` are gone. fmt, vet and the no-TCP gate are clean, all seven RUN
suites pass, and `cyrius distlib --check` reports `dist/` current. `dist/setu.deps` is unchanged: the
same 12 leaves. The DCE smoke binary goes from 16,336 B (sha256 `8cba229012d0`) to 16,344 B
(`56d7e4e78d30`).

## [0.8.12] - 2026-10-10

### Fixed — on Linux a read had no deadline, so a peer that never sent held its reader forever

`setu_read_blk`'s Linux arm was one blocking `read(2)`. Its contract promised -6 on "EOF / peer gone /
error / timeout", and the agnos arm had an 8 s deadline, but Linux had none. A peer that connected and
never sent held the caller forever. In aethersafha (its roadmap D12) that caller is the frame loop:
`setu_srv_accept` → `setu_srv_serve_accepted_at` → `setu_srv_read_msg` → `setu_read_msg` →
`setu_read_blk` on the fd it had just accepted. The compositor stopped drawing, and since aethersafha
0.17.2 blocks SIGINT and reads it from a signalfd once per frame, Ctrl+C could not end it either.

- **Added: a deadline on every read that waits, on both targets.** `setu_read_blk_ms(fd, buf, cap,
  timeout_ms)` and `setu_read_msg_ms(fd, msg_out, timeout_ms)`. `timeout_ms > 0` waits at most that
  many milliseconds on a monotonic clock; `0` does not wait (a record already queued, else a timeout);
  `< 0` has no deadline. They return the record's (or frame's) length, or -6 when no record came, and
  `setu_read_msg_ms` returns a negated `SetuErr` for a record that is not a valid frame, as
  `setu_read_msg` does. A signal neither ends the wait nor restarts it.
- **Added: `setu_read_timed_out()`** says why the last -6 happened: 1 when the deadline passed with the
  connection still open, so a later read may still get a record; 0 for EOF, peer gone or an error,
  which are final. A caller with a short bound has to tell "slow" from "gone", and the -6 alone cannot.
- **`setu_read_blk` and `setu_read_msg` are now defined through them**, with `SETU_READ_DEFAULT_MS`:
  8000 on agnos, -1 (no deadline) on Linux. `setu_recv`, `setu_client_recv` and the `SURFACE_CREATED`
  wait in `setu_client_present` inherit it. The two targets and the timed and default reads cannot
  drift apart.
- ⚠ **Changed: a Linux read now needs a socket.** The arm calls `recv`, not `read(2)`, so an fd that is not
  a socket (a pipe, a file) is ENOTSOCK and -6 at once, where 0.8.11 read it. Every consumer passes setu
  sockets (aethersafha's tests use `socketpair(AF_UNIX, SOCK_SEQPACKET)`), so nothing breaks.
- **Linux waits in poll(2), never in a busy loop.** A recv with `MSG_DONTWAIT` takes a record already
  queued in one syscall. If there is none, poll(2) on the fd for what is left of the deadline (in
  slices of one hour, since poll's timeout is a C int), then recv again. EINTR re-reads the clock and
  waits out only the remainder; EAGAIN after a wakeup waits again; EOF and every other error
  (ECONNRESET, EBADF, ENOTSOCK) are -6 at once. The recv comes first so that a bad fd fails at once:
  poll ignores a negative fd and would sleep out the whole bound. The deadline is tested as
  `deadline - now <= 0`, which stays right when an i64-max bound wraps `now + timeout_ms`. The fd's own
  blocking mode no longer matters to a read. poll has no stdlib wrapper, so it is `syscall(7, …)`, the
  stdlib's own spelling, which the aarch64 backend rewrites to ppoll. The clock is chrono's
  `clock_now_ns` (CLOCK_MONOTONIC), so `src/lib.cyr` now includes `lib/chrono.cyr`.
- **agnos keeps its wait shape.** `chan_recv` answers at once and the loop spins, preemptibly, between
  attempts. Two things change. (1) The deadline is the caller's, and the 5000 extra spins the loop ran
  after its deadline (≈0.1 s, machine-dependent) are gone: they would have dwarfed a frame-sized bound.
  The 8 s default therefore ends ≈0.1 s sooner. (2) The clock is `uptime_us` #95, falling back to
  `uptime_ms` #40 only when #95 answers -1 (TSC calibration refused). Before agnos 1.57.7 a foreground
  `run` program, which is what the compositor is, ran with IF cleared and #40 frozen, so a deadline on
  #40 never arrived in exactly the caller a short bound is for. #95 has existed since agnos 1.56.18,
  before the `#97` band (1.56.40) that setu requires. ⚠ The agnos arm is built here for `--agnos`,
  made reachable by `reach_test`, but not run: CI has no agnos host.

⛔ **The Linux default stays unbounded. That is the compatibility verdict, not an oversight.** Every
call of a blocking read in crab, dhancha and aethersafha was read (below). One relies on an indefinite
wait: dhancha's `dh_setu_read_event`, the body of its public `dh_client_next_event`, which "BLOCKS until a
frame arrives, which suits an app that only changes when input does" (`src/dh_client.cyr`). Its callers
(`programs/setu_session_demo.cyr:72`, `programs/setu_input_client_probe.cyr:37`) end their event loop on
any negative return, so any finite default would disconnect an app that sat idle for longer than it. A
caller that cannot afford to wait names its bound with the `_ms` reads. So no consumer changes behaviour
on Linux until it opts in, and the aethersafha wedge is fixed only when aethersafha switches.

| Call | Waits for | Verdict |
|---|---|---|
| aethersafha `src/setu_dispatch.cyr:68`, `setu_srv_recv_committed` (via `setu_srv_read_msg`, `src/setu_server.cyr:37`) | `CREATE_SURFACE` from a client the Linux frame loop has just accepted (`src/main.cyr:1465`) | The wedge. Must NOT wait indefinitely; aethersafha has to opt in. |
| aethersafha `src/setu_dispatch.cyr:101` and `:129`, `setu_srv_commit_from_create` | `ATTACH` and `COMMIT` after it replied `SURFACE_CREATED`, on the same path | Same: a client that sends `CREATE_SURFACE` and stops wedges it too. |
| aethersafha `src/setu_dispatch.cyr:153` (`setu_srv_create_surface`) and `src/setu_server.cyr:55` (`setu_srv_accept_one`) | one frame, in single-shot probes | Request and reply in a probe. Unaffected. |
| aethersafha `programs/focus_client.cyr:67`, `tests/setu_handshake.tcyr:219` | `SURFACE_CREATED` | Unaffected. |
| aethersafha's agnos placed clients (`src/main.cyr:1377`) | nothing: `setu_srv_handshake_drain` polls with `setu_poll_input` | Never calls the blocking read. Unaffected. |
| crab `src/main.cyr:319` | `SURFACE_CREATED` after its own `CREATE_SURFACE`; -6 exits with "no surface_created reply" | Request and reply; treats -6 as failure. Unaffected. Its input loop polls (`dh_client_poll_event`). |
| dhancha `src/setu_client.cyr:58`, `dh_setu_create_surface` (via `setu_recv`) | `SURFACE_CREATED`, one-shot | Unaffected. |
| dhancha `src/setu_client.cyr:34` and `:36` | forwarders to `setu_recv` / `setu_read_msg` | Take their callers' verdicts. |
| dhancha `src/setu_input.cyr:90`, `dh_setu_read_event` → `dh_client_next_event` | the next input event, for as long as it takes; any negative ends the session | **Relies on an indefinite wait**, which is why the Linux default stays unbounded. |

setu's own waits are request and reply too: `setu__client_create_surface` (the first
`setu_client_present`) and `programs/present_probe.cyr:132`. puka calls no blocking read.

⚠ On agnos the 8 s default already ends a `dh_client_next_event` loop: an idle one returns -6 after 8 s,
which its callers read as the end of the session. That predates this release — EXCEPT for a foreground
`run` program on agnos before 1.57.7: there #40 was frozen, so 0.8.11's deadline never arrived and such a
loop waited forever by accident. On #95 it now ends after 8 s idle like every other agnos caller.
dhancha can wait indefinitely on both targets with `setu_read_msg_ms(fd, m, -1)` (on agnos that spins)
and tell a timeout from an EOF with `setu_read_timed_out()`.

RUN-tested in the new `programs/read_deadline_test.cyr`, over real AF_UNIX / `SOCK_SEQPACKET`
connections with forked peers, every duration measured on the clock the read uses. Measured here
(Linux 7.2.8, x86_64): a silent peer gives up at 300 ms for `setu_read_blk_ms(300)`, 20 ms for 20,
0 ms for 0, and 100 ms for `setu_read_msg_ms(100)`, each with `setu_read_timed_out()` = 1, and the
connection then reads a queued frame normally; a record sent 250 ms late arrives at 250 ms (bound
5000, and -1); one sent 1000 ms late arrives through the Linux default at 1001 ms; an i64-max bound is
no deadline; EOF is -6 in 0 ms with a 5000 ms bound and with the default; so are a reset and a bad fd;
a peer that exits after 250 ms is -6 at 250 ms, not at the bound; with a SIGUSR1 handler installed
without SA_RESTART, a signal at 150 ms and a record at 300 ms return the record at 300 ms (bounded and
default), and a signal at 400 ms with no record times out at 801 ms on an 800 ms bound, not at ~400 or
~1200. And `setu_read_blk` on a silent peer is still waiting at 8.6 s, past the agnos default, then
returns -6 within 1 ms of the peer closing, as EOF and not as a timeout. The suite takes about 9 s and
arms a 60 s watchdog, because a regression here is a hang rather than a wrong answer. EINTR needs a
handler, and the stdlib installs none, so on x86_64 the suite writes the 7-byte `rt_sigreturn` restorer
itself.

**Negative controls: 14 mutants, each killed.** The old one-blocking-`read(2)` arm hangs the suite,
and its watchdog fails it at 60 s. EINTR taken as a failure fails 6 checks; EINTR restarting the whole
bound times out at 1201 ms. A deadline branch that does not set the timed-out flag fails 4 checks.
Reading every recv error as "nothing yet" makes a bad fd sleep out its 5000 ms bound, and so does
polling before the first recv. A Linux default of 8000, a default of 500, and a `setu_read_blk` that
hard-codes 8000 past the constant each fail, the last only on the 8.6 s check. Comparing
`now >= deadline` fails the i64-max bound.

Every consumer builds unchanged against 0.8.12. Each was built in a scratch copy through a `path` dep,
first against 0.8.11 and then against 0.8.12, and their repos were not touched: aethersafha, crab, puka
and dhancha's four setu programs, each for Linux and `--agnos`. aethersafha's `setu_handshake` (92
checks) and `setu_focus` (19) pass on both. dhancha's `poll_test` prints the identical result on both:
exit 3, the three idle checks the 0.8.11 entry recorded.

### Fixed — no socket setu opened was close-on-exec

`setu_listen` created the listener without `SOCK_CLOEXEC`, `setu_accept` called `accept4(sfd, 0, 0,
0)`, and `setu_connect`'s socket had none either, so every process a compositor or a client exec'd
inherited them. aethersafha launches clients by fork and execve (`ae_spawn_client`), so each one held
the listener and every connection accepted before it. puka's PTY child (fork, dup2, execve) and
everything run from that shell held puka's own connection. A copy keeps its socket alive. Measured with a
scratch probe that accepts a client, launches `/bin/sleep` by fork and execve, then closes its end and
its listener: on 0.8.11 the client's next recv reads EAGAIN, a live peer, and a new connect succeeds
into a backlog nothing will accept; on 0.8.12 the client reads EOF at once and the connect is refused.

- **All three are created close-on-exec, atomically** (`accept4` takes `SOCK_CLOEXEC`). Only the
  listener is non-blocking; accepted and connected fds stay blocking, so a send waits for room.
- **No consumer passes a setu fd to a child on purpose.** aethersafha announces the rendezvous path
  (`SETU_SOCKET=<path>`, `src/main.cyr:605`) and the child connects itself. puka's PTY child inherited
  puka's connection by accident. crab launches programs only on agnos, where an inherited end is inert
  (below). dhancha launches nothing.
- **agnos is unchanged and needs nothing.** It has no close-on-exec: `vfs_fd_inherit` gives every child
  a byte copy of its creator's fd table, and `SPAWN_F_CLEANFD` (agnos 1.57.6) is an opt-in scrub. But
  `chan_auth` checks an end's owner on every operation, so an inherited display-channel end is inert
  (`CH_E_BADFD`). An end lives as long as its owner holds it: the owner's close or death releases it
  (`chan_release_pid`), and an inert copy keeps nothing alive. A client holds its end only because the
  compositor endowed it (`CH_ENDOW` moves ownership; aethersafha announces `AGNOS_CHAN=<fd>`). Only an
  end endowed in PTY mode is usable by the owner's descendants (agnos 1.56.46), and setu's are not.

RUN-tested in `unix_transport_test` (`fds_close_on_exec`): `F_GETFD` has `FD_CLOEXEC` on the listener, a
connected fd and an accepted fd, and `F_GETFL` has `O_NONBLOCK` on the listener only. It reads the flag
rather than exec a child, because the CI security scan refuses exec in `programs/`. **Negative
controls:** dropping the flag from any one of the three fails it, and so does adding `SOCK_NONBLOCK` to
the `accept4`.

### Found while doing it

- ⚠ **The write side has the read's shape.** A `SOCK_SEQPACKET` send blocks once the peer's queue is
  full. Measured here over a pair: a peer that never reads takes 278 records of 40 bytes (`INPUT_KEY`),
  then a send would block (`-EAGAIN` under `MSG_DONTWAIT`; `max_dgram_qlen` is 512, so the send buffer is
  the limit). aethersafha's sends to a client (`setu_srv_forward_key`, `setu_srv_notify_focus`) block, so
  a client that stops reading its input can stall the frame loop the same way. Not changed here.
- ⚠ aethersafha's probe paths (`setu_srv_create_surface`, `setu_srv_serve_buffer`,
  `setu_srv_serve_present`, `setu_srv_serve_session`) accept with a raw `syscall(SYS_ACCEPT, …)` rather
  than `setu_accept`, so those fds are not close-on-exec. They are single-shot probes that launch
  nothing. `setu_srv_serve_polled_at` has no caller.
- `buf.cyr`'s `/dev/shm` files are not opened close-on-exec. Each is opened and closed inside one call,
  so a single-threaded program never execs while one is open.

Every program builds for Linux and `--agnos`. Lint reports 0 warnings; fmt, vet and the no-TCP gate are
clean; all five RUN suites pass; `cyrius distlib --check` reports `dist/` current. `dist/setu.deps`
lists the same 12 leaves; `chrono` moved up, because `src/lib.cyr` now includes it.

### Changed — both filed issues are closed and archived

`docs/development/issues/` held two filings. Both were already marked fixed, and both now live in
`issues/archived/`, the stack's convention (cyrius, dhancha, agnos). Each was re-checked against the
tree at 0.8.11 before the move and gained a closing note.

- `2026-08-06-read-msg-is-stream-shaped-on-a-record-transport.md` — fixed in 0.8.2, with its Linux
  regression repaired in 0.8.3. Its two open items are now answered. On the compositor side,
  aethersafha's `setu_srv_read_msg` and `setu_srv_read_exact` delegate to setu. Every frame read goes
  through the one-record `setu_read_msg`, and the only `setu_srv_read_exact` call is the retired
  inline-pixel branch, where it now always fails -6. The repin it waited for happened long ago: every
  consumer pins 0.8.8 or later.
- `2026-08-07-distlib-deps-sidecar-under-reports.md` — fixed upstream in cyrius 6.5.10, and setu's
  workaround script was retired after 0.8.10. Its mirror path now points at cyrius's archived copy,
  and its ask and interim rule are marked answered for base bundles. Profile bundles keep the pruned
  inference by cyrius's design.

References follow the move: the sidecar gate's comment in `.github/workflows/ci.yml` and the 0.8.10
and 0.8.2 entries below. ⚠ Two pointers outside this repo still name the old paths: cyrius's archived
mirror of the sidecar issue, and a line in agnos's CHANGELOG naming the read_msg filing.

Docs only: this entry changes nothing under `src/`.

## [0.8.11] - 2026-09-26

### Removed

- **`scripts/sync-deps-sidecar.sh`.** It rewrote `dist/setu.deps` from `[deps] stdlib` because
  `cyrius distlib` once emitted 8 of setu's 12 leaves. cyrius 6.5.10 fixed that upstream: the sidecar
  is now the declared list unioned with an include scan. On 6.6.6, raw `distlib` output lists the
  same 12 leaves as the script and differs only in its header comment and leaf order, so the script
  had stopped correcting anything. All it still produced was churn: `e4c7bc3`, `562b335` and
  `f05ee6f` each committed distlib's own sidecar, and `9c76252`, `3397603` and `83f558f` each
  rewrote it back.

### Changed

- **`dist/setu.deps` is committed exactly as `cyrius distlib` writes it.** Consumers see the same 12
  leaves. Only the header comment and the position of `io` change. `dist/setu.cyr` is unchanged.
- **CI verifies all of `dist/` with `cyrius distlib --check`**, replacing both the "Verify dist bundle
  is in sync with src/" step (`distlib`, then `git diff dist/setu.cyr`) and the script's sidecar
  step. `--check` regenerates into a temp file beside `dist/` and byte-compares the bundle and the
  sidecar, writing nothing. Plain `cyrius distlib` still runs after it, for the bundle self-compile
  (see below).
- **A separate CI step checks that the sidecar covers every declared leaf.** It compares the
  non-comment lines of `dist/setu.deps` with the `[deps] stdlib` array and fails if a declared leaf
  is missing. That is the property the script protected, now asserted directly in case a later
  toolchain regresses the 6.5.10 fix. A superset passes, because the include scan can add a leaf the
  declaration lacks.
- `docs/development/overview.md` no longer tells anyone to run the script, and the distlib sidecar
  issue doc records the retirement under Resolution.

### Found while retiring it

- ⚠ **The old sidecar gate never saw an uncommitted sidecar.** It ran `git diff dist/setu.deps`
  after regenerating, and an untracked file has no diff, so a commit that dropped `dist/setu.deps`
  passed. `--check` fails it (measured both ways).
- ⛔ **`--check` skips distlib's bundle self-compile**, which is why plain `distlib` still runs after
  it. Measured on 6.6.6: a module only the bundle includes, with a syntax error and committed as
  distlib wrote it, reads `current` under `--check`. Plain `distlib` exits 1 on it ("the generated
  bundle does not compile"), and no other CI step fails, because the programs build through
  `src/lib.cyr`. The order matters: plain `distlib` rewrites `dist/`, so running it first would leave
  `--check` nothing stale to find.
- ⚠ **For the eventual prune:** `vec`, `str` and `assert` stay in the sidecar even when undeclared,
  because `src/lib.cyr` includes them and the include scan keeps them. `result`, `net` and `chrono`
  do drop out when undeclared. `docs/development/overview.md` now says so.

### Fixed — comments that still described TCP and `SCM_RIGHTS` fd passing

0.8.4 removed TCP from setu on both targets, and setu's code has never passed an fd: `ATTACH` sent
inline pixels at 0.2.0 and has named a shared buffer by integer id (`buf_id`, arg5, argc 6) since
0.3.1. Comments in `src/`, two programs and the no-TCP gate still described TCP-on-loopback, and an
`SCM_RIGHTS` fd hand-off that setu never implemented. ⛔ Not cosmetic, for the reason 0.8.1 recorded:
a comment that describes a deleted transport reads as a statement about the code in front of you. And
`dist/setu.cyr` ships comments verbatim, so every consumer's materialized `lib/setu.cyr` carried them.

- `src/proto.cyr` — the ABI table, the `SETU_ATTACH` enum comment and `SETU_MAX_ARGS`'s note give
  ATTACH its six args. The ATTACH NOTE and both constructors describe the shared buffer: no fd is
  passed, `buf_id = 0` is the legacy inline form that no real surface fits, and the connection fd
  belongs to `client.cyr`. The ABI heading says frozen for 0.x (it said v0.1), and the header names
  the GUI clients, not only dhancha.
- `src/codec.cyr` — transport lives in `client.cyr`, not "in each side" with `SCM_RIGHTS`.
- `src/lib.cyr` — the transport is the `#97` channel on agnos and AF_UNIX / `SOCK_SEQPACKET` on
  Linux, not "the persistent AF_UNIX connection". `client.cyr` gives the compositor listen/accept on
  Linux, and nothing is accepted on agnos. crab is listed, and the module-order note covers `buf.cyr`
  and `client.cyr`.
- `src/buf.cyr` — the buffer exists because setu sends at most 64 B per record and a surface is
  hundreds of KB, not to dodge a `TCP_RX_RING` deadlock. The inline path is no longer "the
  multi-core fallback", and the agnos arm is `#86` then `#71`, not "STUBBED".
- `src/client.cyr` — the per-target semantics block, the `setu_conn_err` / `setu_conn_rc` notes, the
  headers of `setu_listen`, `setu_write_all`, `setu_read_blk`, `setu_recv`, `setu_poll_input`,
  `setu_read_exact`, `setu_read_msg`, `setu_client_connect` and `setu_client_recv`, and the idle
  branch of `setu_client_poll_input`. They described `sock_recv #49` / `sock_send #48`,
  `sys_sock_connect`, the 30 s `_agnos_sock_recv_block` stall, length-from-header stream reads, a
  listener "kept only until §9.6 lands" and an `anu` migration still to come. They now describe the
  `#97` band and `SOCK_SEQPACKET` as the code uses them. The band has no codename: agnos `ipc.md` §9
  dropped `anu` on 2026-08-05.
- `programs/present_probe.cyr`'s header no longer says it dials loopback:7700 "pending anu", and its
  connect-failure note no longer points at the raw `#47` return. `programs/client_test.cyr` no longer
  asserts "the well-known transport port". `scripts/check-no-tcp-on-agnos.sh` no longer calls Linux
  code "legitimately allowed to speak TCP".

⚠ One comment now states a behaviour it used to blur: on Linux `setu_client_poll_input` reads EOF and
recv errors as idle (0), where `setu_poll_input` returns -6 for EOF. The old comment said
"EOF-as-idle" and also claimed the two functions matched. That behaviour is fixed in its own entry
below.

Left alone: `setu_client_present`'s header and inline-fallback comments. That path sends ATTACH with
`buf_id = 0` and then has its pixel write refused by the 64-byte rule. It is a behaviour bug, fixed
in its own entry below.

**No code change** — comments and the regenerated bundle only. All six programs build byte-identical
before and after on Linux and `--agnos` (12 binaries compared). Lint reports 0 warnings; fmt, vet and
the no-TCP gate are clean; all four RUN suites pass; `cyrius distlib --check` reports `dist/` current,
and `dist/setu.deps` is unchanged.

### Fixed — `setu_client_present` sent an ATTACH whose pixels could never follow

When no shared buffer could be created or written, `setu_client_present` fell back to inline pixels:
`ATTACH` with `buf_id = 0` ("pixels follow this frame"), then the pixels through `setu_write_all`.
Since 0.8.0 (agnos) and 0.8.4 (Linux) that function refuses any write over 64 bytes, because one send
is one record. So for any surface over 16 pixels the ATTACH went out and the pixels did not: present
returned -43 and left the compositor holding an ATTACH that promised pixels. At 16 pixels or fewer
the write fit, and present returned 0 while the pixels arrived as a separate record that nothing reads
as pixels. Both reproduced over a real `SOCK_SEQPACKET` pair.

There was nothing to fall back to anyway: aethersafha refuses the inline form on both of its handlers
(the placed-client handshake returns -12, and the accept path gets -6 from `setu_read_exact`). On
agnos each stray ATTACH counted as a handshake failure, and 200 in a row retired the client with
"attach refused". The path is reachable: agnos has 16 shm slots system-wide, a `#71` slot holds at
most 2 MB and QEMU has no other kind, and a `/dev/shm` write can fail on Linux.

- **The inline fallback is gone, and the buffer comes first.** present makes and fills the shared
  buffer before it sends anything, including the first present's `CREATE_SURFACE`, so a failed
  present leaves the wire as it was. With no buffer it returns **-45** (the create failed) or **-46**
  (the write failed), and presenting again is a clean retry. A failed write still drops the cached
  id, so the retry makes a fresh buffer. -43 is no longer returned.
- ⚠ **Why before `CREATE_SURFACE` too:** otherwise a failed first present still creates the surface,
  and aethersafha mints a window that gets no pixels (agnos) or blocks in its accept-path read waiting
  for the ATTACH (Linux).
- Wire format and API are unchanged, and `setu_attach` stays in the codec. No consumer matches -43
  (checked puka, dhancha, cyrius-doom, crab and aethersafha). README and
  `docs/development/overview.md` now call the inline form retired.

RUN-tested in `unix_transport_test`, which now checks what a present puts on the wire when no buffer is
available. A directory at the next `/dev/shm/setu-buf-<id>` path makes the create fail, and one in
place of the cached buffer's file makes the write fail. Each must return its code with nothing sent,
and the next present must recover: `CREATE_SURFACE`, ATTACH by id and COMMIT the first time, ATTACH
with a fresh id the second, with the buffer holding the frame. **Negative controls:** against the old
code the test fails 6 assertions (rc -43, `ATTACH` with `buf_id = 0` on the wire); with the handshake
moved back ahead of the buffer, it fails on the `CREATE_SURFACE` that reaches the wire.

Every program builds for Linux and `--agnos`. Lint reports 0 warnings; fmt, vet and the no-TCP gate
are clean; all four RUN suites pass; `cyrius distlib --check` reports `dist/` current, and
`dist/setu.deps` is unchanged.

### Fixed — a resize freed the buffer the compositor reads before its replacement existed

`setu_client_present` handled a resize by freeing the cached shared buffer, then creating one at the
new size. aethersafha re-reads the buffer id it was last attached every frame, so when that create
failed, the client had nothing to present from and the compositor kept reading a freed slot id. agnos
hands out the lowest free slot and `shm_read` #73 reads any valid slot, so the next client to create a
buffer could be given that id and have its pixels shown in this window. Under QEMU that is what
growing a window past 2 MB does: there is no GPU carveout for `#86`, and a `#71` slot holds at most
2 MB. crab met the same failure in its own present path and already creates before it closes.

- **A resize now makes and fills the new buffer first**, and frees the old one only after an ATTACH
  naming the new one has gone out. If the create, the write or the first present's handshake fails,
  the replacement is freed and the old buffer stays cached and intact, still showing the last good
  frame; present returns its code with nothing sent, as before. A client can keep presenting at the
  size it has.
- ⚠ **Trade-off, chosen deliberately:** for the length of one present the client holds two slots.
  With all 16 agnos slots in use, a resize now fails (-45) where freeing first would have made room,
  and the window keeps its old size until a slot frees. Freeing first destroyed the working buffer
  whenever the create failed for any other reason, and setu cannot tell the two apart: both return -1.
- The old slot is now freed right after the ATTACH instead of before the create, so the compositor
  can read a freed slot for less time: until it processes that ATTACH. Closing the gap entirely needs
  a buffer-release message in the protocol.

RUN-tested in `unix_transport_test`, steps 5-9 of the present section: a grow whose create fails (a
directory at the next `/dev/shm` path), a grow that succeeds, a grow whose replacement cannot be
written (a symlink to `/dev/full` lets the create succeed and the write get ENOSPC), a present at the
held size afterwards, and a retry at a new size after a first-present handshake failure (a reply of
the wrong kind, -8). **Negative controls:** close-then-create fails 9 assertions. Four mutants of the
fix each fail at least one: freeing the held buffer as soon as the replacement exists, never freeing
the old one, keeping a replacement whose write failed, and keeping one after a failed handshake.

Every program builds for Linux and `--agnos`. Lint reports 0 warnings; fmt, vet and the no-TCP gate
are clean; all four RUN suites pass; `cyrius distlib --check` reports `dist/` current, and
`dist/setu.deps` is unchanged.

### Fixed — on Linux, `setu_client_poll_input` never reported the compositor gone

Its Linux arm turned every `recvfrom` return that was not a record into "nothing pending" (0): EAGAIN,
but also EOF and every error. So on Linux it could never return -6, although its header has promised
-6 on EOF/error since it was written. A client whose compositor closed or crashed without sending
`SETU_CLOSE` polled an idle channel forever; 0.8.6 records what a client that outlives its window
costs. crab exits on -6 ("crab: connection closed -- exiting", reached through dhancha's
`dh_client_poll_event`), so on Linux that exit could never fire.

⚠ **Not deliberate.** It dates from 0.5.1, when one `sys_read` served both targets and agnos TCP's 0
meant would-block, so Linux's 0 (EOF) fell into the same idle branch. The comment named the side
effect ("EOF-as-idle") and gave no reason. 0.8.1 mapped agnos `PEERGONE` onto the EOF return. When
0.8.4 moved both Linux polls to `MSG_DONTWAIT`, it gave `setu_poll_input` an explicit `EOF → -6` but
mapped every negative to idle here.

- **EAGAIN is the only "nothing pending".** EOF and every other error now come back as -6 once
  nothing is buffered, and frames already buffered are still handed out first. Measured over a real
  `SOCK_SEQPACKET` pair: after a clean close every later `recvfrom` reads 0; a close that leaves one of
  the client's records unread reads -ECONNRESET once, then 0; an fd that was never valid reads -EBADF.
  The poll turned all three into 0, and now turns all three into -6.
- The header says -6 holds on both targets, and says to drain *while* the poll returns 1 rather than
  "until 0": -6 is final, and a loop waiting for 0 would spin on it. No consumer loops that way;
  dhancha, cyrius-doom and puka all branch on the value.
- agnos is untouched: all six programs build byte-identical for `--agnos` before and after.
- ⚠ **Consumers.** crab gains its EOF exit on Linux at its next local build, since it builds setu from
  `path = "../setu"`. puka treats any result but 1 as "no event", so it neither breaks nor gains the
  exit until `win_poll_events` maps -6 to `WIN_EV_CLOSE`. **dhancha's `programs/poll_test.cyr` fails 3
  checks against this** (measured): its clients use fd -1 and expect 0 once drained, which held only
  because -EBADF read as idle. dhancha resolves setu's 0.8.9 tag, so the test breaks when it bumps that
  tag or re-enables its dormant `path`.
- ⚠ Not changed: `setu_poll_input`'s Linux arm still reads every negative as idle. It does report EOF,
  so a clean close surfaces at once and a reset one poll later, but an fd error would idle forever.
  aethersafha polls client fds through it, so changing it is a separate decision.

RUN-tested in `unix_transport_test` (`poll_sees_peer_gone`): a live, silent peer must poll idle (the
negative control for EAGAIN); after a clean close with two frames queued in one record, both frames
come out and then -6, twice; a close with a client record unread gives -6; so does an fd of -1.
**Negative controls:** against the old code the test fails 4 assertions, every -6 reading 0. Three
mutants each fail: mapping EAGAIN before EOF (a live peer reads as gone), dropping the EOF mapping (the
clean close reads idle), and keeping every error idle (the reset and the bad fd read idle).

Every program builds for Linux and `--agnos`. Lint reports 0 warnings; fmt, vet and the no-TCP gate
are clean; all four RUN suites pass; `cyrius distlib --check` reports `dist/` current, and
`dist/setu.deps` is unchanged.

## [0.8.10] - 2026-09-26

### Changed

- **Toolchain `6.6.2` → `6.6.6`**, back in step with dhancha, the consumer the pin tracks. No source
  change. The vendored `lib/` is re-synced to the 6.6.6 stdlib (`cyrius lib sync --full`; the
  installed snapshot is byte-identical to cyrius's `6.6.6` tag). The declared `[deps] stdlib` is
  unchanged, so `dist/setu.deps` is unchanged and `dist/setu.cyr` differs only in its version line.

  Every program builds for Linux and `--agnos`, lint reports 0 warnings, fmt, vet and the
  no-TCP-on-agnos gate are clean, and all four RUN suites pass: `client_test`, `codec_test`,
  `reach_test`, `unix_transport_test`. Unlike 0.8.7's bump, this one is not byte-identical (most
  binaries are about 4 KB larger), so the RUN suites are what show behaviour held.

- **`cyrius.cyml` is configuration only.** It had accumulated a per-module dependency ledger, the
  toolchain-pin rationale, build and distlib notes, and a dated agnos cutover note. The durable parts
  now live in `docs/development/overview.md` (Module order, Toolchain, Dependencies); the history was
  already here (0.3.0 for `net` / `result` / `chrono`, 0.8.0 for `args`). The package description
  no longer says "No I/O in the lib", which has been false since the 0.2.0 client transport.

  ⚠ Comments inside `stdlib = [...]` were also a latent parse hazard. cyrius's
  `_parse_toml_str_array` collects every `"…"` up to the first `]`, comments included, so a quote
  or bracket in one of those comments would have silently changed the dep list.

### Found while moving the ledger

- ⚠ **Six declared stdlib leaves are not referenced by setu's code**: `vec`, `str`, `assert`,
  `result`, `net`, `chrono`. All twelve builds (six programs, two targets) stay clean with them
  undeclared, singly or together; `vec` and `result` are compiled in anyway, because `fmt` and `io`
  include them. `args` is still load-bearing, via `argc()` / `args_init()` in two test programs. The
  ledger's reasons for `net`, `result` and `chrono` described the TCP transport and a read-retry
  sleep that 0.8.4 and 0.8.2 removed. They are **not** pruned here, because pruning changes what
  `dist/setu.deps` tells consumers to declare.
- Since 6.6.6, `io.cyr` includes `args_agnos.cyr` itself, so `getenv` on agnos no longer depends on
  a consumer declaring `args`.
- The `distlib` sidecar issue (`docs/development/issues/archived/2026-08-07-distlib-deps-sidecar-under-reports.md`)
  was fixed upstream in cyrius 6.5.10 and is now marked resolved. Raw `distlib` emits all 12 leaves
  on 6.6.0 through 6.6.6; `scripts/sync-deps-sidecar.sh` stays as a redundant gate.

## [0.8.9] - 2026-09-11

### Changed

- **Toolchain `6.5.27` → `6.6.2`.** No source change. setu builds no `Result`
  surface — it deleted its TCP arm at 0.8.5–0.8.8 and speaks AF_UNIX/SOCK_SEQPACKET,
  so it has no socket call whose `Result` could be compared against a negative, and
  no `is_err_result` / `?` site anywhere. Zero compiler rejections, zero fail-open
  sites, zero collisions; the four `callptr` sites reach no pair-returning target.

  All four RUN suites pass: `client_test`, `codec_test`, `reach_test`,
  `unix_transport_test`.

## [0.8.8] - 2026-08-27 — `SETU_INPUT_PTR_SCROLL`: the wheel reaches clients

### Added

- **`SETU_INPUT_PTR_SCROLL` (kind 12)** — `S->C: id, delta`. Signed, summed since the compositor's
  last forward, **positive = wheel-up** (away from the user), matching the sign agnos reports in HID
  report byte [3] and bhumi carries as `BHUMI_EV_SCROLL`. `setu_input_ptr_scroll(id, delta)`.
- `SETU_KIND_MAX` 11 → 12; argc table entry 2; `setu_kind_name` entry.

⛔ **A SEPARATE KIND, NOT A BUTTON CODE.** X11 spends buttons 4/5 on wheel detents. Doing that here
would make `SETU_INPUT_PTR_BTN`'s `button` argument mean two different things, and would silently turn
a scroll into a click on any client that range-checks buttons rather than enumerating them.

⚠ **Two args, not four — a scroll carries no position.** The pointer is wherever the last
`SETU_INPUT_PTR_MOVE` put it. Clients already track position themselves because
`SETU_INPUT_PTR_BTN` carries none either; duplicating x/y here would invite trusting a stale pair.

⚠ **This kind is only useful with agnos >= 1.56.49 and bhumi >= 1.4.3.** Before those the wheel byte
was discarded in the kernel's HID drain — byte [3] of the boot-mouse report was documented and never
read — so nothing upstream could produce a delta to forward.

### Testing

`codec_test` covers the round trip in both directions (the delta is signed; a wheel-down arriving as a
large positive would scroll a client to the end of its list), the argc table entry, and the
`SETU_KIND_MAX` range. Mutation-verified: leaving `SETU_KIND_MAX` at 11 fails, and a wrong argc fails
— the latter is the one that would have presented as "the compositor sends scrolls and no client ever
receives one", because `setu_msg_validate` rejects on the wire rather than at the call site.

## [0.8.7] - 2026-08-17 — toolchain pin to 6.5.27

### Changed — `cyrius = "6.5.20"` -> **6.5.27**

Stack-wide sweep so every repo in the desktop stack declares one toolchain. Pins had drifted across
three lines (6.5.5 / 6.5.20 / 6.5.21) while the installed wrapper was 6.5.27, so every build ran with
a drift warning and the declared graph did not describe what was actually compiled.

⚠ **Measured byte-identical**: 6.5.20 and 6.5.27 produce the same artifact for this repo, so the bump carries no codegen risk here. Recorded because a pin that is assumed to be cosmetic is how a real change gets waved through later.

⚠ The vendored `lib/` was re-synced to the 6.5.27 bundled set, which clears the
`./lib/ shadows version-pinned` warning. Tests re-run green after both changes.

## [0.8.6] - 2026-08-17 — `present_probe` honours SETU_CLOSE instead of leaking a slot per launch

### Fixed — the slim probe outlived its window and held a system-wide resource for the whole boot

⛔⛔ **MEASURED ON IRON (1.56.44 and 1.56.45 burns): the compositor's `#86` slot budget fell
16 → 15 → 14 → 13, one slot per desktop launch.** `present_probe` ignored `SETU_CLOSE` and span in its
animation loop forever, so when the compositor exited and told its clients to close, this one did not —
keeping one of only **16** GPU-visible shm slots, a `#97` channel end and a process-table row until
reboot. Ceiling: roughly 16 desktop launches per boot.

⚠ **It was the ONLY client that did this.** crab and puka both honour the message — QEMU, same boot:
`crab: compositor closed the window -- exiting` / `puka: compositor closed the window -- exiting`.
⛔ And puka's own source records the identical defect being fixed *in puka* on 2026-08-08: *"the
terminal was left orphaned ALIVE holding one of only 16 system-wide shm slots for the rest of the
boot."* The probe never received that fix, then inherited the exposure when it was staged into the
`/bin/puka` slot as the default — so a fix that had already been paid for came back through a substitute.

⇒ The loop now clears a `live` flag on `SETU_CLOSE` and falls out. ⚠ The teardown is not the message,
it is the process EXIT: dying is what returns the slot and the channel end to the kernel.

## [0.8.5] - 2026-08-12 — one place names the rendezvous

⭐ **`setu_un_path` now resolves `$SETU_SOCKET`**, so a caller passing `0` means "ask setu". Precedence
is explicit path > `$SETU_SOCKET` > `SETU_UNIX_PATH`.

⛔ **What this replaces: four repos each spelling the same literal.** aethersafha, crab, puka and this
repo's own `present_probe` all hardcoded `"/tmp/aethersafha-setu.sock"`, while `SETU_UNIX_PATH` sat
here **unreachable because nothing ever passed 0**. ⚠ They agreed, so nothing was broken — the hazard
was that four files had to be edited in step for that to stay true, and a fifth answer existed that no
caller could reach. ⚠ And the override was worse than the default: **puka implemented `$SETU_SOCKET`
itself while crab and present_probe did not**, so it worked for one client in three.

⚠ **The default name is protocol-shaped, not compositor-shaped.** setu owns the wire, so the socket is
`/tmp/setu-display.sock` and a second compositor speaking setu binds the same place; `$SETU_SOCKET` is
how two coexist on one box. ⛔ Consumers must move together — a server binding setu's default while
clients still dial their own literal fails every connect with ENOENT (measured while getting this
wrong the first time).

### Changed — `programs/present_probe.cyr` passes 0

Also drops a stale comment claiming the path was *"advisory; transport is loopback:7700"*, which
predated both the AF_UNIX cutover and this change.

### ⚠ `dist/setu.deps` regenerated with `scripts/sync-deps-sidecar.sh`, not left as distlib wrote it

⛔ **`cyrius distlib` OVERWRITES the sidecar with a fixed core subset** — 8 leaves where setu declares
12, dropping `result`/`net`/`chrono`/`args`. This cut's distlib run clobbered it and CI caught it, which
is exactly what that gate exists for: a consumer declaring only the 8 builds "OK" on agnos with no
error and merely warns `undefined function 'sys_uptime_ms'` on Linux, whereas a correct sidecar makes
cyrius HARD ERROR in the consumer's own repo.
⇒ **After any `cyrius distlib` here, run `sh scripts/sync-deps-sidecar.sh` before committing.**
⚠ Verified stable through CI's exact sequence (distlib → sync → diff), and idempotent.
⚠ No new leaf was needed for 0.8.5: `getenv` lives in `lib/io.cyr` and `io` was already declared.

### Changed — toolchain pin 6.5.8 → **6.5.20**

`cyrius lib sync --full`. ⚠ `unix_transport_test` still PASSes — record boundaries preserved in both
directions, which is the property three consecutive cuts were lost to.

## [0.8.4] — 2026-08-07 — TCP is GONE from setu. Linux speaks AF_UNIX/SOCK_SEQPACKET.

⛔⛔ **THE RULING WAS THAT TCP-ON-LOOPBACK IS THE WRONG PRIMITIVE FOR LOCAL DISPLAY IPC — A PROPERTY OF
THE PROBLEM, NOT OF THE KERNEL.** 0.8.0–0.8.3 scoped the removal to agnos and kept Linux on TCP behind
a rationalisation ("Linux is a different target, not a fallback") that was never asked for. That left
the rejected primitive alive on the target easiest to keep testing against, where it survived four
cuts while every changelog and planning doc asserted it was gone.

⛔ **AND THE agnos REMOVAL ITSELF WAS INCOMPLETE.** 0.8.0 states "the TCP arm is DELETED on agnos". It
was deleted from `setu_connect` only. `setu_listen` and `setu_accept` kept calling `tcp_socket` /
`sock_bind(INADDR_LOOPBACK(), 7700)` / `sock_listen` / `sock_accept` with no `#ifdef` around any of it.
ipc bite 8's premise — *"nothing dials 7700/7701"* — was false the entire time it was treated as
reachable.

### Changed — Linux transport is AF_UNIX / SOCK_SEQPACKET

`setu_connect` / `setu_listen` / `setu_accept` now use `AF_UNIX` + `SOCK_SEQPACKET` via raw syscalls,
with a `sockaddr_un` built by `setu_un_addr` and a filesystem path as the rendezvous. Its permissions
are the access control loopback:7700 never had — anything on the host could dial a port.

⭐ **SOCK_SEQPACKET is the same semantic as the `#97` channel band**: local, connected, record-framed,
all-or-nothing delivery. That is not a coincidence — the band's own host semantic proof
(`agnos/tests/chan/chantest.cyr`) is written against `socketpair(SOCK_SEQPACKET)`, with a `SOCK_STREAM`
negative control that fails exactly its six framing assertions.

⚠ **setu 0.1.0 WAS AF_UNIX.** TCP was adopted at 0.3.0 because agnos had a TCP stack and no AF_UNIX —
reuse, not design. This restores the original primitive on the host and pairs it with the sovereign one.

⛔ `setu_listen` **unlinks the path before binding.** An AF_UNIX node outlives its process, so a
compositor killed without a clean shutdown leaves it behind and every later bind fails `EADDRINUSE` —
the same "run 2 hosts nothing and looks perfectly healthy" failure the leaked TCP listener had. The fix
belongs at bind time, not in a shutdown path a crash skips.

⛔ **`sys_read` in the poll paths was a real bug on Linux too** — it blocks on a blocking fd, so a poll
documented as "never stalls" stalled the frame loop whenever no input was pending. Both polls now use
`MSG_DONTWAIT` per call, leaving the fd blocking so `setu_read_blk` can still block.

### Changed — `setu_read_msg` has NO `#ifdef` any more

Both arms are record transports, so one record is one message on both and the function has **one body**.
The two targets can no longer drift on framing — which is the entire class of bug that caused three
consecutive releases. `setu_write_all` applies the same one-record rule on both arms, and
`setu_read_exact` now refuses on both (a stream idiom with no meaning on either transport).

### Added — `scripts/check-no-tcp-on-agnos.sh`, gated in CI

Strips every `#ifndef CYRIUS_TARGET_AGNOS` block and fails if any TCP symbol remains in agnos-active
code. ⭐ It caught a real remnant on its first run — `var SETU_TCP_PORT = 7700` was still compiled on
agnos — so it is not vacuous. **A claim in a changelog is not a property of the code; this makes it one.**

### Added — `programs/unix_transport_test.cyr`, a real wire test

`reach_test` proves the surface links; `client_test` proves the codec round-trips in memory. Neither
opens a socket. This one binds, connects, accepts, and exchanges framed messages in **both** directions
in a single process (AF_UNIX `connect()` completes against a listening socket before `accept()`).

⭐ **The load-bearing assertion is record framing.** Two writes of 24 and 16 bytes must come back as two
reads of exactly 24 and 16 — no coalescing, no splitting. **Negative control run before trusting it:**
with `SOCK_STREAM` substituted, the test fails `rec1 read len got=40 want=24` and then hangs waiting for
a record that never arrives (exit 124). Everything else in the test passes on `SOCK_STREAM`.

### Fixed — stale comments that described the deleted transport

The file banner and three call-site comments still documented TCP-on-loopback, `net.cyr` routing, and
"pending the anu migration". ⛔ Not cosmetic: 0.8.1's own changelog names a stale comment as the reason
0.8.0's bug survived review, and these were still present three cuts later. `aethersafha` carried the
same rot — a comment reading "ON agnos THE COMPOSITOR NO LONGER LISTENS" sat directly above code that
still opened loopback:7700.

### Changed — the transport uses the stdlib's per-arch syscall wrappers; setu has no private syscall table

`sys_socket` / `sys_connect` / `sys_bind` / `sys_listen` / `sys_accept4` / `sys_recvfrom` /
`sys_unlinkat` all already exist in `lib/syscalls_linux_common.cyr`, are per-arch correct, and need no
renumber chain. setu calls those. `sys_accept4(fd, 0, 0, 0)` is defined to be exactly
`accept(fd, NULL, NULL)` — the same swap bote 3.2.1 shipped for the same reason.

⛔ **THE FIRST CUT OF THIS ARM HARDCODED RAW x86 SYSCALL NUMBERS, ON TWO WRONG CONCLUSIONS.**
Recorded because the reasoning failure is more reusable than the fix:

1. *"cyrius has no wrappers for this"* — reached by reading `net.cyr`, which genuinely has no AF_UNIX,
   and not checking the syscall **peers**, where every needed wrapper already lived.
2. *"`ESYSXLAT` has no socket rows, so raw x86 numbers break on aarch64"* — reached by reading the
   **macho** block (`emit.cyr:760-773`). The Linux x86-compat socket block is at `:865-873` and does
   contain `41→198 · 42→203 · 43→202 · 49→200 · 50→201`.

⚠ **Both errors pointed the same way — toward hand-rolling — and would have produced a PARTIALLY
correct result on aarch64, which is the worst outcome.** Five of the seven numbers are renumbered by
that block; `recvfrom` (45) is not in it at all, and `unlink` (87) cannot be renumbered on principle,
because aarch64 Linux has no `unlink(2)` — only `unlinkat(AT_FDCWD, path, 0)`, a different **arity**.
A renumber chain rewrites `x8`; it cannot add an argument. The working majority would have read as
evidence the pattern was sound.

Both items are now filed against the root cyrius ticket
(`2026-07-30-net-cyr-x86-only-socket-syscall-numbers.md` §5a and §9), together with the underlying
gap: `net.cyr` exposes no `AF_UNIX`, no `SOCK_SEQPACKET`, and no `sockaddr_un` builder, which is why
both known consumers left the stdlib rather than from any preference for raw syscalls.

⚠ Consumers (`aethersafha`, `crab`) hold a TEMP `path = "../setu"` override until this is tagged.

## [0.8.3] — 2026-08-07 — 0.8.2 broke every Linux consumer, and CI could not see it

⛔ **`sys_uptime_ms` EXISTS ONLY ON AGNOS, AND 0.8.2 READ IT OUTSIDE THE `#ifdef`.** The wall-clock
deadline added to `setu_read_blk` was hoisted to the top of the function, so the Linux build
referenced a symbol that has no Linux definition (`syscalls_x86_64_agnos.cyr:1090` is the only one).
`deadline` is now declared unconditionally and **assigned only under `#ifdef CYRIUS_TARGET_AGNOS`**.

⛔ **AND SETU'S OWN GATES SAID GREEN.** `smoke.cyr` links the include chain but *calls nothing*, so
cycc's DCE marked the entire client surface unreachable and demoted the undefined function to
`warning: undefined function`. Both setu targets built clean and 0.8.2 was tagged. The first consumer
that actually reached it — `crab`, on Linux — got
`error: refusing to emit binary with 1 reachable undefined function(s)`.

### Added — `programs/reach_test.cyr`, a reachability gate

Calls **every** public transport entry point (connect/listen/accept, write_all/send, read_blk/
read_exact/read_msg/recv/poll_input, the whole `setu_client_*` surface, and `setu_buf_*`) behind an
`argc() > 99` guard: false in every real invocation, **not provably false at compile time**, so the
call sites stay reachable for DCE while nothing executes. The gate is the compiler's undefined-symbol
refusal, not a runtime assertion.

⚠ A literal `if (0)` would be folded away and take the reachability — the entire point — with it.

**Negative control, run before trusting it.** With 0.8.2's hoist restored: `smoke.cyr` on Linux → `OK`
(missed it); `reach_test.cyr` on Linux → `FAIL`. With the fix: `OK`. The gate also caught *its own
first draft* being wrong — `setu_chan_floor_ok` / `setu_chan_announced_fd` are agnos-only by design
(they live inside `#ifdef` in `client.cyr`), so calling them unguarded asserted a surface the lib never
promised. Now gated the same way.

### Added — CI builds the `--agnos` target

⛔ **CI BUILT ONLY LINUX, AND SETU'S AGNOS ARM IS THE ONE THAT MATTERS.** Three consecutive cuts shipped
agnos-arm defects through a green pipeline: **0.8.0** left both poll paths on `sys_read`, **0.8.1** left
`setu_read_msg` stream-shaped, **0.8.2** hoisted an agnos-only symbol. A pipeline that never builds the
target cannot be evidence about it. `smoke.cyr` and every `programs/*_test.cyr` now build under
`--agnos`. They cannot be *run* — no agnos host — but each of those three defects was compile- or
link-visible on that arm, so the build is a sufficient gate.

⚠ **The three-in-a-row is the signal, not the individual bugs.** Each was found by a downstream
consumer rather than by setu, which is what a missing target gate looks like from the inside.

## [0.8.2] — 2026-08-07 — `setu_read_msg` was still stream-shaped on a record transport

⛔ **THE HANDSHAKE READ NEVER MOVED OFF THE STREAM SHAPE.** 0.8.0/0.8.1 converted `setu_connect`,
`setu_write_all`, `setu_read_blk` and both poll paths — but `setu_read_msg` still opened with
`setu_read_exact(fd, buf, 16)` to peek a header, then read the remainder in a second call. That is a
**byte-stream** idiom, and on the channel band `setu_read_exact` is the one function whose agnos arm
deliberately *refuses* (`0 - 6`). So every agnos client that awaited `SURFACE_CREATED` failed at the
first read, immediately, with the reply already sitting in its inbox.

A record transport delivers all-or-nothing per SEND, so the header/body split has nothing to buy:

    var r = setu_read_blk(fd, buf, 128);      # one record == one message
    if (r <= 0) { return 0 - 6; }
    return setu_decode(buf, r, msg_out);

⛔ **`sys_sleep_ms` removed from `setu_read_blk`'s agnos retry.** It is the `preempt_disable; sti; hlt`
spin ipc.md §9.4 names as the poison that made TCP toxic: a client blocking for `SURFACE_CREATED`
starved the **compositor** that had to send it. Replaced with a preemptible spin under a wall-clock
`sys_uptime_ms()` deadline — the retry counter alone timed out in ~0.1 s, which is not a block at all.

⚠ **How it hid for a whole debugging session.** `present_probe` presented fine, because it never calls
`setu_read_msg` on that path — so "one client works, the other doesn't" read as a *compositor* bug and
sent the search into the kernel. Kernel tracing proved the reply was sent and never received; the
client-side read was the last place looked. A partial cutover is diagnosed by whichever consumer
happens to exercise the unconverted function.

⚠ **And a dep-resolution trap doubled the cost.** `cyrius build` re-resolves `[deps]` and **overwrites**
the consumer's `lib/setu.cyr` from the pinned tag — so hand-patching a consumer's materialized copy to
add a diagnostic is silently reverted before the compiler ever sees it. Several instrumented runs were
therefore vacuous: they measured tag 0.8.1 while appearing to measure the fix. Verify a materialized lib
**after** the build, not before, or use a `path` override.
[[reference_never_fix_in_materialized_libs]] · [[reference_path_override_disables_the_tag_as_a_test]]

Proven on agnos 1.56.40 under QEMU `-smp 4`: two independent clients (`present_probe` + `crab`)
connect over endowed channels and both present — `presented: 2`, framebuffer-confirmed at 3500
client-coloured pixels.

### Changed — `cyrius.cyml` single-sources the version from `VERSION`

`version` was a hardcoded `"0.8.1"` string while `release.yml` states in its own log line that
*"cyrius.cyml pulls from VERSION via ${file:VERSION}"*. It did not. The release gate only compares
`VERSION` to the tag, so the manifest could sit a cut behind with **CI green** — and it did. Now
`version = "${file:VERSION}"`, which makes the workflow's claim true and leaves one source of truth.
`README.md`'s version line was three cuts stale (`0.7.2`) and is corrected to match.

### Fixed — `dist/setu.deps` is a dep contract again, and it re-arms a machine check

⛔ **A WRONG SIDECAR DOES NOT JUST MISLEAD A READER — IT SWITCHES OFF `cyrius deps`' OWN VALIDATION.**
`cyrius distlib` emits **8** stdlib leaves where setu declares **12**, dropping `result`, `net`,
`chrono`, `args`. Measured against a throwaway consumer on the agnos target:

| sidecar | consumer declares | result |
|---|---|---|
| corrected (12) | 8 | ⭐ hard error — `dep setu requires 'chrono' but it is not in the cyrius stdlib` |
| raw distlib (8) | 8 | ⛔ **`OK`** — builds clean, no error, no warning |

`cyrius deps` validates a consumer's `[deps] stdlib` against the dep's sidecar correctly and loudly.
The under-reporting sidecar simply tells it there is nothing to complain about. So the consequence is
not "a human might read the wrong list" — it is that the check built to catch this mistake was off.

setu now ships **`scripts/sync-deps-sidecar.sh`**, which rewrites `dist/setu.deps` from the declared
`[deps] stdlib` after every `cyrius distlib`, plus a **CI gate** that fails on drift. setu owns
`dist/`, so setu states the truth there rather than waiting on another repo. ⚠ `distlib` overwrites
the sidecar, so the sync script must run **after** it — that ordering is why this is a gate and not a
one-time edit.

Root defect filed against cyrius (both repos):
[`2026-08-07-distlib-deps-sidecar-under-reports.md`](docs/development/issues/archived/2026-08-07-distlib-deps-sidecar-under-reports.md).

## [0.8.1] — 2026-08-06 — the cutover missed both poll paths

⛔ **0.8.0 CUT OVER THE RECORD AND STREAM HALVES AND LEFT THE POLL HALF ON `sys_read`.**
`setu_poll_input` and `setu_client_poll_input` — every client's **per-frame input poll** — still called
`sys_read` on what is now a channel fd. A channel fd does not route through `sys_read` at all, so on
agnos those polls read nothing: **no client would have received a single key or input event.**

⛔ **The comment is what made it survive review.** It read *"agnos: non-blocking (0 = would-block, -1 =
EOF)"* — accurate for the old TCP fd's stdlib wrapper, and meaningless for a channel. A stale comment
that describes the transport you just deleted reads as a statement about the code in front of you.

⛔ **And a partial cutover is worse than none, because the working paths hide it.** `present_probe`
built, `setu_connect` returned, and a send/recv round-trip succeeded — so nothing in the build or the
smoke said the input leg was dead. Found only by auditing every remaining `sys_read`/`sys_write` in
`src/` while wiring the compositor side.

Both now use `sys_chan_recv`, mapping `-CH_E_WOULDBLOCK` onto each function's existing "idle" return and
`-CH_E_PEERGONE` onto its EOF return. The reassembly buffer in `setu_client_poll_input` stays: a record
is all-or-nothing per SEND, but a client may still need more than one record to complete a frame, and
the take/partial logic is transport-agnostic.

**Audit result, so the next reader does not redo it:** three `sys_read` calls remain in `src/client.cyr`
(`setu_read_blk`, `setu_poll_input`, `setu_client_poll_input`) and all three are inside
`#ifndef CYRIUS_TARGET_AGNOS` arms — verified by walking the preprocessor arms, not by eye. `buf.cyr`'s
reads and writes are on **files** opened by path (`sys_open`), the Linux shm-file arm — not channel fds,
correctly untouched.

Both targets build; `dist/setu.cyr` regenerated and idempotent.

## [0.8.0] — 2026-08-06 — the agnos client no longer dials anything (channel-band cutover, bite 6)

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

### ⛔ Consumers must add `args` to their `[deps] stdlib` when they repin

The agnos arm reads `getenv("AGNOS_CHAN")`, which resolves to `_agnos_getenv` (`args_agnos.cyr`) —
agnos has no `/proc`, so `io.cyr`'s `getenv` delegates there. **`dist/setu.deps` does NOT list it.**

⚠ The sidecar under-reports in general — it names 8 leaves (`string fmt alloc vec str io syscalls
assert`) while this package's own `[deps] stdlib` needs 12; `net`, `chrono` and `result` are missing
too, and were before this release. Verified by building a throwaway consumer with *exactly* the
sidecar's 8 leaves against `dist/setu.cyr` under `--agnos`: it fails on `_agnos_getenv` (plus
`tcp_socket` / `sock_bind` / `INADDR_LOOPBACK` / `sock_close` from the absent `net`). So the sidecar is
a starting point, not a contract — and `args` is the one this release newly requires.

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
