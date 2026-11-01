# gve: leave refcount headroom in the RX page bias

A fix for the Linux `gve` driver (gVNIC on Google Cloud), with the
reproducer and the analysis behind it.

**The bug.** gve sets every RX page's refcount to `INT_MAX` up front and
hands references to the stack by decrementing its own `pagecnt_bias`, so
passing a buffer up costs no atomic. That leaves no headroom: a fresh page's
buffer sits in an skb at exactly `INT_MAX`, and the first `get_page()` from
the stack wraps the count negative. `splice()` of received TCP data into a
pipe takes exactly that reference.

**What breaks.** `splice()` from the pipe into a TCP socket fails with `EIO`
(6.5+), so proxies that relay with `splice(2)`, such as Go's `io.Copy` and
HAProxy's splice options, cut connections short. `tee()` of the pipe fails
with `EFAULT` on any kernel with the bias. On GQI, gve's own reuse check sees
`page_count() < pagecnt_bias`, warns, and resets the device, dropping every
connection on the NIC; pinning a fresh RX page is enough to trigger it.

**The fix.** Use a bias of `USHRT_MAX` in a `u16`, as igb, igc, ixgbe, i40e
and hns3 do, so the type bounds it and the count keeps ample headroom. When
the bias runs out, add a fixed batch of references instead of topping the
count back up to `INT_MAX`, so the refill can't go negative or race.

## Reproduce

Create a VM. C3 needs the 6.12 kernel Debian 13 ships; N2 is affected on
every kernel but gets virtio-net unless gVNIC is asked for:

```sh
gcloud compute instances create gve-repro --machine-type=c3-standard-4 \
    --image-family=debian-13 --image-project=debian-cloud --zone=us-central1-a
# or
gcloud compute instances create gve-repro --machine-type=n2-standard-4 \
    --image-family=debian-13 --image-project=debian-cloud --zone=us-central1-a \
    --network-interface=nic-type=GVNIC

gcloud compute ssh gve-repro --zone=us-central1-a
```

On the VM:

```sh
sudo apt-get install -y git
git clone https://github.com/AmaanC/kernel-bias && cd kernel-bias
URL=http://deb.debian.org/debian/dists/bookworm/main/binary-amd64/Packages.xz PORT=8808 ./reproduce.sh
```

The script resizes the RX ring so gve allocates fresh pages, starts
`relay.py`, a proxy that relays with `splice(2)`, downloads the file 100
times through it and counts the errors. A few minutes later, on an affected
VM:

```
complete downloads:  0 of 100
EIO from splice():   100
kernel warnings since the ring resize (sudo dmesg):
  [192412.224458] WARNING: CPU: 5 PID: 1198138 at net/core/skbuff.c:7324 skb_splice_from_iter+0x118/0x300
  [192412.374141] RDX: 0000000080000000 RSI: ff34c0bcc1881c00 RDI: ff89153145163c60
BUG PRESENT: splice() failed with EIO 100 times, tee() with EFAULT 0 times.
```

`RDX` is the page's refcount at the check: `0x80000000` is `INT_MAX + 1`.
`URL=` must be outside the VM so the bytes arrive through gve; `PORT=` is
any free local port; `RUNS=` changes the count. Exit status: 1 bug present,
0 no bug, 2 inconclusive, with the reason printed.

To see `tee()` fail too, have the proxy `tee()` each chunk into a spare
pipe. On kernels before 6.5, where `splice()` into a socket doesn't check
the page, the script does this by itself:

```sh
RELAY="relay.py --tee" URL=http://deb.debian.org/debian/dists/bookworm/main/binary-amd64/Packages.xz PORT=8808 ./reproduce.sh
```

```
EIO from splice():   98
EFAULT from tee():   267
kernel warnings since the ring resize (sudo dmesg):
  [257711.144551] WARNING: CPU: 7 PID: 3008617 at include/linux/mm.h:1456 generic_pipe_buf_get+0x51/0x60
  [257711.484572] WARNING: CPU: 3 PID: 3008617 at net/core/skbuff.c:7324 skb_splice_from_iter+0x118/0x300
  [257711.639589] RDX: 0000000080000000 RSI: ff34c0ba1ec28600 RDI: ff89153141c13be0
BUG PRESENT: splice() failed with EIO 98 times, tee() with EFAULT 267 times.
```

If it doesn't show:

- `INCONCLUSIVE: ens4 uses virtio_net, not gve`: the VM has a virtio NIC,
  which can't be changed afterwards. Delete it and create one with
  `--network-interface=nic-type=GVNIC`.
- `INCONCLUSIVE: DQO-RDA on ... uses page_pool`: kernels 6.13 and newer
  aren't affected on C3. Use N2, or a 6.12 image.
- `NO BUG` on a VM that should be affected: the bug needs fresh pages. The
  script resizes the ring for that; where `ethtool -G` isn't supported,
  reload the driver and run again at once:

  ```sh
  sudo systemd-run --quiet --wait --collect --unit=gve-reload sh -c 'modprobe -r gve; modprobe gve'
  URL=http://deb.debian.org/debian/dists/bookworm/main/binary-amd64/Packages.xz PORT=8808 ./reproduce.sh
  ```

## Tested on

| Kernel | VM | Format | Stock | Fixed |
|---|---|---|---|---|
| 6.12.113 (Debian 13) | n2-standard-8 | GQI-QPL | `EIO` ×78 in 100 | 100 of 100 |
| 6.12.113 (Debian 13) | c3-standard-4 | DQO-RDA | `EIO` ×36 in 100 | 100 of 100 |
| 6.12.113 (Debian 13) | c3d-standard-4, AMD SEV | DQO-RDA | `EIO` ×42 in 100 | 100 of 100 |
| v7.3 mainline | n2-standard-8 | GQI-QPL | `EIO` ×77 in 100 | 100 of 100 |
| 7.0 (Ubuntu 24.04) | c3-standard-4, Intel TDX | DQO-RDA | not affected | not affected |

DQO-RDA moved to page_pool in 6.13, so on 7.x only GQI and DQO-QPL are
affected. The fix also passed with the bias forced to 1, with `--tee`, and
behind Go and HAProxy proxies; built `allmodconfig W=1` clean.

## What's here

| | |
|---|---|
| [`patches/`](patches/) | The signed `[PATCH net]`, based on netdev/net [`d8a4f4c59da5`](https://git.kernel.org/pub/scm/linux/kernel/git/netdev/net.git/commit/?id=d8a4f4c59da52b7c31ae337243b8473a19a3f819), and its SHA-256 (`sha256sum -c patches/SHA256SUMS`). Backports to 6.12.y, 6.6.y, 6.1.y and 5.15.y differ only in context and can be regenerated from it |
| [`relay.py`](relay.py), [`reproduce.sh`](reproduce.sh) | The reproducer and the script around it |
| [`docs/call-graph.md`](docs/call-graph.md) | One RX page from allocation to `EIO`, `EFAULT` and the reset, in code; why the fix is correct; the kprobes that measured it |
| [`docs/call-graph-igb.md`](docs/call-graph-igb.md) | The same path through igb, which uses the same trick safely, and why |

## Upstream status

Sent to netdev on 2026-10-31:
[lore](https://lore.kernel.org/all/20261031173449.2439047-1-amaan.cheval@gmail.com/),
[patchwork](https://patchwork.kernel.org/project/netdevbpf/patch/20261031173449.2439047-1-amaan.cheval@gmail.com/).

## License

GPL-2.0, as the driver. See [LICENSE](LICENSE).
