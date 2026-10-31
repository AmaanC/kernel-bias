# Why igb doesn't have the bug

igb, the driver for Intel's 1 GbE cards (82575, 82576, I350, I210 and
others), uses the same trick as gve: it pays for page references in
advance, with a bias, so that handing a buffer to the stack needs no atomic
op. Its pages go through the same `splice()` path and the same check. It
doesn't hit the bug. This file follows one igb RX page the way
[call-graph.md](call-graph.md) follows a gve page, and shows why.

Line numbers are from Linux 6.12.113, the version the gve tests ran on.
The igb runs below were done in a small QEMU VM with an emulated
igb (and virtio-net as a second control), relaying downloads of an 8 MiB
file through a Go `io.Copy` proxy; that harness isn't part of this repo.

## The short version

In the terms of [call-graph.md](call-graph.md#the-short-version): igb takes
65,535 tickets per box (`USHRT_MAX`), not every number the counter can hold.
A new box's counter says 65,535, and the pipe's extra ticket takes it to
65,536, nowhere near the 2,147,483,647 where the counter rolls over. When
igb runs out of tickets, it adds another batch. And when anyone else still
holds tickets on a box igb wants to reuse, igb gives the box up for good and
gets a new one.

Make igb take `INT_MAX` tickets, as gve does, and it fails the same way,
with the same warning. That was done, as a control: see
[The control](#the-control-igb-with-gves-bias).

## Side by side

| | gve, before the fix | igb |
|---|---|---|
| Bias field | `int pagecnt_bias` (gve.h) | `__u16 pagecnt_bias` (igb.h:288) |
| Starting bias | `INT_MAX` | `USHRT_MAX` |
| Refcount of a new page | 2,147,483,647 | 65,535 |
| Room left for the stack's own references | 0 | 2,147,418,112 |
| Refill | fill back up to `INT_MAX`: add `INT_MAX - page_count()` | add `USHRT_MAX - 1` when the bias is down to 1 |
| When the stack still holds a page | in QPL mode, keep it (QPL pages are registered with the device) and copy into another page | let it go, and allocate a new page |
| After `splice()` takes a reference to a new page | `INT_MAX + 1`, read as negative: rejected | 65,536: sent |

## Step 0: igb allocates a page

```
igb_alloc_rx_buffers()                           igb_main.c:9076
└─ igb_alloc_mapped_page()                       igb_main.c:9029
     page = dev_alloc_pages(...)                 a new page, refcount 1
     dma_map_page_attrs(...)
     page_ref_add(page, USHRT_MAX - 1);          igb_main.c:9065
     bi->pagecnt_bias = USHRT_MAX;               igb_main.c:9066
```

State of a new page: refcount 65,535, bias 65,535, stack holds 0. Room
below `INT_MAX`: 2,147,418,112.

## Step 1: a packet arrives and igb hands the page to the stack

```
igb_poll()                                       igb_main.c:8193
└─ igb_clean_rx_irq()                            igb_main.c:8873
   ├─ igb_get_rx_buffer()                        igb_main.c:8826
   │    rx_buf_pgcnt = page_count(page);         igb_main.c:8832  read first
   │    rx_buffer->pagecnt_bias--;               igb_main.c:8847  one reference to the skb
   ├─ igb_build_skb()                            igb_main.c:8548
   │    napi_build_skb() builds the skb around this half of the page:
   │    the page is the skb's head, and no get_page() is needed
   ├─ igb_put_rx_buffer()                        igb_main.c:8852
   │  └─ igb_can_reuse_rx_page()                 igb_main.c:8432
   │       if (rx_buf_pgcnt - pagecnt_bias > 1)  igb_main.c:8444
   │               return false;                 someone else holds the page
   │       if (pagecnt_bias == 1) {              igb_main.c:8458  refill
   │               page_ref_add(page, USHRT_MAX - 1);
   │               rx_buffer->pagecnt_bias = USHRT_MAX;
   │       }
   │  ├─ reusable: igb_reuse_rx_page()           igb_main.c:8410
   │  │    the page's other half goes back to the ring
   │  └─ not reusable:
   │       __page_frag_cache_drain(page, pagecnt_bias);   igb_main.c:8865
   │       drops all of igb's remaining references in one atomic op.
   │       The page now belongs to the stack alone, and the ring gets a
   │       new page at the next refill (step 0).
   └─ napi_gro_receive()                         igb_main.c:8992
```

State after the page's first packet: refcount 65,535, bias 65,534, stack
holds 1.

`rx_buf_pgcnt` is read before the handout, so `rx_buf_pgcnt - pagecnt_bias`
counts the stack's references plus the one just handed out. More than 1
means the stack still holds the page's other half, or extra references such
as a pipe's. igb then lets the page go instead of keeping it.

So igb never keeps a page that others still reference, and its pages don't
build up a history, as gve's QPL pages do. While `splice()` holds
references, igb lets pages go often, so many packets land in new pages. A
new page is exactly the case that breaks gve. igb is safe there only
because its bias is small.

## Steps 2 and 3: splice() into a pipe, then into a socket

The same code as for gve: `spd_fill_page()` takes a reference with
`get_page()` (skbuff.c:3137), and `skb_splice_from_iter()` checks
`sendpage_ok()` (skbuff.c:7324). See steps 2 and 3 in
[call-graph.md](call-graph.md).

One difference. gve puts its pages in an skb's frags, and the skb's head is
a small separate buffer, not one of gve's pages. igb builds the skb around
its page, so the page is the head. `__skb_splice_bits()` maps a head by
reference too, unless the head is locked: not a page fragment, or shared
with a clone (skbuff.c:3192-3201, `skb_head_is_locked()`). igb's head is a
page fragment, so the pipe takes a reference to igb's page either way.

| A new page | refcount | `sendpage_ok()` |
|---|---|---|
| set up | 65,535 | |
| a packet in an skb | 65,535 | |
| a pipe holds a reference | 65,536 | passes |
| both halves out, each in a pipe | 65,537 | passes |

## Why the bias stays safe

The rules in [call-graph.md](call-graph.md#why-the-fix-is-correct) hold for
igb too:

1. **refcount = bias + the stack's references.** The same bookkeeping as
   gve.
2. **igb always owns a reference to a page it uses.** It refills when the
   bias is down to 1, before it reaches 0, and drops the page entirely,
   bias and all, once it stops using it.
3. **igb leaves room for everyone else.** Its bias is never above 65,535, so
   the refcount is at most 65,535 plus the stack's references. The refill
   adds a batch instead of filling the count to a maximum.

The bias field being a `__u16` is what keeps it small: `USHRT_MAX` is the
largest value it can hold. gve's field is an `int`, as wide as the refcount
itself, and its largest value leaves the refcount no room.

## The control: igb with gve's bias

igb was rebuilt with these changes, and nothing else:

```diff
-	__u16 pagecnt_bias;
+	__u32 pagecnt_bias;
-		page_ref_add(page, USHRT_MAX - 1);
-		rx_buffer->pagecnt_bias = USHRT_MAX;
+		page_ref_add(page, INT_MAX - 1);
+		rx_buffer->pagecnt_bias = INT_MAX;
-	page_ref_add(page, USHRT_MAX - 1);
-	bi->pagecnt_bias = USHRT_MAX;
+	page_ref_add(page, INT_MAX - 1);
+	bi->pagecnt_bias = INT_MAX;
```

Then 48 of 50 downloads are cut short by `EIO`, with gve's warning, at the
same line, with the same refcount in RDX:

```
WARNING: CPU: 1 PID: 158 at net/core/skbuff.c:7324 skb_splice_from_iter+0x118/0x300
RDX: 0000000080000000 RSI: ff4293e8fe644e00 RDI: ff71f525c0477c70
```

So nothing else in igb's path protects it: only the size of the bias does.
It fails more often than gve does with the same proxy (48 of 50, against
about half), probably because igb puts many packets in new pages, which
have no room at all.

## Other drivers

Every driver in the `net` tree that pays for page references in advance:

| Driver | Bias | Counted in |
|---|---|---|
| **gve, before the fix** | **`INT_MAX`** | **the page refcount** |
| igb, igc, ixgbe, ixgbevf, i40e, hns3 | `USHRT_MAX` | the page refcount |
| funeth | 1,000,000, topped up below 1,000 | the page refcount |
| thunder (nicvf) | 256 in XDP mode, else 1 | the page refcount |
| fbnic, mpnic | `PAGE_SIZE` | page_pool's own counter, not the page refcount |

gve is the only one with no room left. To list them in any kernel tree:

```sh
git grep -nE 'page_ref_add\(|pagecnt_bias = ' -- drivers/net
```

## Results

In QEMU, 50 downloads of an 8 MiB file per NIC, on kernel 6.12.113:

| NIC | Bias | Complete | Cut short by `EIO` |
|---|---|---|---|
| igb | `USHRT_MAX` | 50 of 50 | 0 |
| igb, rebuilt | `INT_MAX` | 2 of 50 | 48, with the warning |
| virtio-net | none | 50 of 50 | 0 |
