# gve: leave refcount headroom in the RX page bias

A fix for the Linux `gve` driver (Google Virtual NIC, gVNIC on Google
Cloud), with the reproducer and the analysis behind it.

**The bug.** gve's GQI and DQO-QPL RX paths set every RX page's refcount to
`INT_MAX` up front and hand references to the network stack by decrementing
a driver-side `pagecnt_bias`, so that passing a buffer up costs no atomic
operation. That leaves the page no headroom: while a fresh page's buffer sits
in an skb, `page->_refcount` is already `INT_MAX`, and a single `get_page()`
from the stack wraps it negative. `splice()` of received TCP data into a pipe
takes exactly such a reference. The count reads as `INT_MIN`, the
`RDX: 0000000080000000` in the kernel's warning.

**Impact.**

- `splice()` from the pipe into a TCP socket fails with `EIO` (kernels 6.5
  and later): `skb_splice_from_iter()` sees `page_count() < 1`. TCP proxies
  that relay with `splice(2)`, such as Go programs that `io.Copy` between
  two TCP connections, or HAProxy with `option splice-response`, cut
  downloads short or stall.
- `tee()` of the pipe fails with `EFAULT`, on any kernel with the bias:
  `try_get_page()` refuses the page.
- On GQI, gve's own reuse check `gve_rx_can_recycle_buffer()` sees
  `page_count() < pagecnt_bias`, warns, and calls `gve_schedule_reset()`:
  a device-wide reset that drops every connection on the NIC. A task that
  merely pins a fresh RX page (say, by holding spliced data in a `tee()`
  pipe it never drains) can trigger it.

**The fix.** Use a bias of `USHRT_MAX`, stored in a `u16`, as igb, igc,
ixgbe, i40e and hns3 do: the bias only has to make the per-packet atomic
rare, and the type bounds it, so `page_count()` keeps ample headroom below
`INT_MAX`. When the bias runs out, add a fixed batch of references and set
the bias to it, instead of topping the count back up to `INT_MAX - page_count()`,
which keeps the stack's share of the count intact without reading it and so
cannot go negative or race. It is
[`patches/net-gve-leave-refcount-headroom-in-the-RX-page-bias.patch`](patches/net-gve-leave-refcount-headroom-in-the-RX-page-bias.patch),
a `[PATCH net]` based on netdev/net commit
[`d8a4f4c59da5`](https://git.kernel.org/pub/scm/linux/kernel/git/netdev/net.git/commit/?id=d8a4f4c59da52b7c31ae337243b8473a19a3f819)
(7.3 cycle). Backports to 6.12.y, 6.6.y, 6.1.y and 5.15.y differ only in
context lines, file names (6.12 and older set the DQO bias in
`gve_rx_dqo.c`) and the number of bias sites (6.1 has no GQI copy pool,
5.15 no GQI bias); they can be regenerated from the `net` patch. The
6.12.y one was what the Debian 13 runs below used.

## What's here

| | |
|---|---|
| [`patches/`](patches/) | The fix, for the `net` tree, signed off, and its SHA-256 (`sha256sum -c patches/SHA256SUMS`) |
| [`relay.py`](relay.py) | The reproducer: a TCP proxy that relays with `splice(2)`, and with `--tee` also `tee(2)` |
| [`reproduce.sh`](reproduce.sh) | Fresh RX pages, 200 downloads through `relay.py`, count the `EIO`s |
| [`docs/call-graph.md`](docs/call-graph.md) | One RX page from allocation to `EIO`, `EFAULT` and the reset, in code; why the fix is correct; the kprobes that measured it |
| [`docs/call-graph-igb.md`](docs/call-graph-igb.md) | The same path through igb, which uses the same trick and doesn't have the bug, and why |

## Reproduce

You need a Google Cloud VM with a gVNIC interface in an affected queue
format and an unpatched kernel. The reliable choice today is an **N2 VM
running Debian 13** (GQI-QPL, kernel 6.12): every GQI machine series is
affected on every kernel since 5.16, including mainline. C3 and other
DQO-RDA series are affected only on kernels up to 6.12 (Debian 13 qualifies;
Ubuntu 24.04's 7.0 kernel does not). From a machine with `gcloud`:

```sh
gcloud compute instances create gve-repro --machine-type=n2-standard-4 \
    --image-family=debian-13 --image-project=debian-cloud --zone=us-central1-a
gcloud compute ssh gve-repro --zone=us-central1-a
```

On the VM (it needs `sudo`, `curl`, `ethtool`, `python3` and `git`, all of
which Debian 13's image has):

```sh
git clone https://github.com/AmaanC/kernel-bias && cd kernel-bias
./reproduce.sh
```

It checks that the NIC is gve and in a format that has the bias, resizes
the RX ring so gve allocates fresh pages (the network drops for about a
second), starts `relay.py`, downloads a file from the Debian mirror 200
times through it, and ends with the verdict and the kernel's own warnings
from this run. It takes a few minutes. On an affected VM:

```
== 5. Result
complete downloads:  0 of 100
EIO from splice():   100
EFAULT from tee():   not checked (RELAY="relay.py --tee" checks it)
kernel warnings since the ring resize (sudo dmesg):
  [192412.224458] WARNING: CPU: 5 PID: 1198138 at net/core/skbuff.c:7324 skb_splice_from_iter+0x118/0x300
  [192412.374141] RDX: 0000000080000000 RSI: ff34c0bcc1881c00 RDI: ff89153145163c60

BUG PRESENT: splice() failed with EIO 100 times, tee() with EFAULT 0 times.
For the full traces: sudo dmesg | grep -A20 'skb_splice_from_iter\|generic_pipe_buf_get'
```

(That run: Debian 13, 6.12.113, DQO-RDA, `RUNS=100`. On GQI-QPL VMs 20
to 80 of 100 typically fail; the share depends on how fresh the pages are.)

`RDX` is the page's refcount at the check: `0x80000000` is `INT_MAX + 1`,
wrapped negative. The full trace is in `sudo dmesg`. With
`RELAY="relay.py --tee"` (automatic on kernels before 6.5, where `splice()`
into a socket doesn't check the page) you also get `EFAULT` from `tee()`
and its warning, `at include/linux/mm.h:... generic_pipe_buf_get`. Exit
status 1 means bug present, 0 no bug, 2 inconclusive, with the reason
printed.

That's the sequence in the patch's changelog, in one script:

```sh
ethtool -G eth0 rx 512 && ethtool -G eth0 rx 1024   # fresh RX pages
./relay.py $HOST 8080 &                              # splice()s both ways
for i in $(seq 200); do curl -so /dev/null \
    --connect-to $HOST:80:127.0.0.1:8080 http://$HOST/file; done
```

**If it doesn't show.**

- *`INCONCLUSIVE: ... uses page_pool`*: a DQO-RDA VM on 6.13 or newer
  isn't affected. Use an N2 (GQI) VM, or an older kernel.
- *`NO BUG` on a VM that should be affected*: the failures need fresh
  pages. The script resizes the ring for that; if `ethtool -G` isn't
  supported, reload the driver (`sudo modprobe -r gve && sudo modprobe gve`)
  and run again right away. A VM that has been passing traffic for a while
  without a resize completes every download.
- *No warning in dmesg, but EIOs counted*: the kernel prints each warning
  once per boot. The script re-arms it through debugfs
  (`/sys/kernel/debug/clear_warn_once`); without debugfs, the warning from
  an earlier run this boot is the one to look at.
- *The file must come from another host* over the gve NIC (`URL=`
  overrides the mirror). Anything served from the VM itself goes over
  loopback and never touches gve.

**To verify the fix**, build gve for the running kernel with the patch and
load it in place of the stock module (`modprobe -r gve; insmod gve.ko`), then
run `reproduce.sh` again. The patch applies with `-p6` to the driver
directory extracted from the kernel.org tree at the kernel's version. The
module is only loaded, never installed: a reboot brings the stock driver
back. Expect the network to drop for a few seconds, and have a second way in.

## Tested on

| Kernel | VM | Queue format | Stock driver | Fixed driver |
|---|---|---|---|---|
| 6.12.113 (Debian 13) | n2-standard-8 | GQI-QPL | `EIO` ×78 in 100 | 100 of 100 |
| 6.12.113 (Debian 13) | c3-standard-4 | DQO-RDA | `EIO` ×36 in 100 | 100 of 100 |
| 6.12.113 (Debian 13) | c3d-standard-4, AMD SEV | DQO-RDA | `EIO` ×42 in 100 | 100 of 100 |
| v7.3 mainline, built | n2-standard-8 | GQI-QPL | `EIO` ×77 in 100 | 100 of 100 |
| 7.0 (Ubuntu 24.04 linux-gcp) | c3-standard-4, Intel TDX | DQO-RDA | no bug: page_pool | no bug |

The N2 runs used the `net` patch (on v7.3) and its 6.12.y backport; the C3
runs the 6.12.y backport, where DQO-RDA still used the bias. DQO-RDA moved
to page_pool in 6.13 (commit
[`ebdfae0d377b`](https://git.kernel.org/torvalds/c/ebdfae0d377b)), so on
7.x only GQI-QPL, GQI-RDA and DQO-QPL remain affected; DQO-QPL runs the same
code but no VM type tried uses it. On the stock 6.12.113 GQI-QPL VM the fix
was also run with the bias forced to 1, with `relay.py --tee`, and with Go
`io.Copy` and HAProxy proxies: all downloads completed. The `net` patch was
built with `allmodconfig W=1` with no new warnings; kernel selftests were
not run.

## Upstream status

Not yet sent. The signed `[PATCH net]` in `patches/` is what will go to
netdev; the lore link will be added here once it is on the list.

## Acknowledgments

**Amaan Cheval** found the bug, led the investigation and directed the
experiments, verified the patch's logic and correctness both with and
without the AI agents, by reading the driver, the splice code and the
netdev archives directly, and decided along the way what to hand to an
agent (an explainer, a harness, a draft) and what to check by hand. Much
of the work was in navigating the strengths and the pitfalls of
AI-assisted Linux kernel debugging and development.

**Claude Code with Claude Opus 4.8** was the main collaborator: it read the
driver and the splice and pipe code, wrote the reproducer, the first
versions of the fix and of these documents, and ran the tests under
direction. **Claude Opus 5.5** and **Claude Fable 5.1** helped where they
could, with later analysis, review passes and the assembly of this repo.
Every commit here carries all three as co-authors.

## License

GPL-2.0, as the driver. See [LICENSE](LICENSE).
