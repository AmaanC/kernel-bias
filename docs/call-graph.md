# What happens when the bug fires

This is the full path of one RX page, from the moment gve allocates it to the
moment `splice()` fails with `EIO`. Line numbers are from Linux 6.12.113, the
kernel the probes and disassembly below were taken on (Debian 13's
6.12.113-1 has the same gve source). [call-graph-igb.md](call-graph-igb.md)
follows the same path through igb, which doesn't have the bug.

## The short version

Think of an RX page as a box of received data, with a counter on the lid:
how many parts of the kernel are using the box. When the counter drops to
zero, the box is recycled. The counter can count up to 2,147,483,647
(`INT_MAX`). One more, and it rolls over to −2,147,483,648, like an odometer
that rolls over into negative numbers.

Changing the counter is slower than changing an ordinary number, because
every CPU has to agree on its value. So gve changes it as rarely as it can.
When it gets a new box, it adds a whole batch of uses to the counter at
once, like tickets bought in advance, and writes down how many of those
tickets it still holds. Giving the box to the network stack then means
handing over one of those tickets: gve's note goes down by one, and the
counter doesn't change.

The bug is the size of the batch: gve takes `INT_MAX` tickets, every number
the counter can hold. In the test, step by step:

1. `reproduce.sh` resizes the RX ring. gve throws its boxes away and gets new
   ones. Each counter says `INT_MAX`, and gve holds all of those tickets.
2. curl downloads a file through relay.py. The data comes in through the
   network card, into gve's boxes.
3. gve gives each box to the network stack, with one of its tickets. The
   counter still says `INT_MAX`.
4. relay.py calls `splice()` to move the data into a pipe without copying
   it. The pipe takes a ticket of its own. The counter goes to `INT_MAX + 1`,
   which rolls over to −2,147,483,648.
5. relay.py calls `splice()` again, to move the data from the pipe into
   curl's socket. The socket checks the box before sending it: a negative
   count means a broken box, so it refuses it. `splice()` fails with `EIO`,
   relay.py drops the connection, and curl gets part of the file.
   (`tee()` checks the box before it takes a ticket, and fails with `EFAULT`.)

A box that has been in use for a while usually has room: each ticket that
comes back from the stack leaves room for one extra ticket. New boxes have
none. That's why the bug shows up after boot, and after a ring resize.

**The fix** has gve take 65,535 tickets at a time (`USHRT_MAX`), as Intel's
drivers do. The trick works as well: the counter changes once every 65,535
times gve hands the box out, instead of every time. And the counter keeps
more than two billion numbers free for everyone else. When gve has handed
out all its tickets, it takes another 65,535: it adds them, instead of
filling the counter back up to the top, as the old code did. And gve's note
now only has room for numbers up to 65,535 (a `u16`), so nobody can make
the batch big again by mistake.

Why that's correct, and not just enough to pass the test:

- **Everyone's tickets fit.** gve never holds more than 65,535 tickets, so
  the counter can only roll over if the rest of the kernel holds more than
  2,147,418,112 uses of one box. Nothing does, and that would break any
  page, not just gve's.
- **gve's note is always right.** The counter always equals gve's tickets
  plus everyone else's, so gve knows exactly when nobody else is using a
  box, and it can reuse it.
- **gve always holds at least one ticket for a box it uses,** so the box
  can't be recycled under it. The old refill worked out how many tickets to
  take by subtracting the ones everyone else holds. With batches of 65,535,
  that could come out negative, because others can hold more than 65,535
  tickets on one box: `tee()` into enough pipes does it. Adding a new batch
  can't go negative.

With a batch of one ticket, the trick turns into the plain way: one counter
change per packet. The fix passes the test that way too.

The rest of this file is the same story in code. [Why the fix is
correct](#why-the-fix-is-correct) has the argument in full.

## The setup

```
 curl ──loopback──▶ relay.py ──ens4 (gve)──▶ deb.debian.org (Fastly)
      127.0.0.1:8080     │
                         │ thread "up->client", per connection:
                         │   splice(upstream socket → pipe)    # step 2
                         │   splice(pipe → client socket)      # step 3
```

The download direction fails: upstream to client. Data arrives on the gve NIC,
lands in gve RX pages, gets spliced into a pipe by reference, then gets spliced
out of the pipe into the loopback socket to curl, still by reference. No byte
is copied, so the client socket ends up sending the same physical page gve
received into.

## Why gve keeps a bias

Every page has a reference count, `page->_refcount`. It's an `atomic_t`, a
signed 32-bit int that any CPU may change at any time, so every change is an
atomic instruction. `get_page()` ends in `atomic_inc()`, which on x86 is
`lock incl` (arch/x86/include/asm/atomic.h:53). `page_ref_add()` is
`lock addl`.

The `lock` prefix isn't a lock in the mutex sense: nothing waits for a lock
holder. It makes the CPU own the cache line that holds the count for the
length of the instruction. Buffers are handed to the stack on the CPU that
polls the RX queue, and their references are dropped on whichever CPU frees
the skb, often the one where the application reads the socket. So the line
moves between CPUs, and each locked instruction waits for it.

One `get_page()` per buffer would pay that on every packet. gve pays it in
bulk instead, as several Intel drivers do. When it sets up a page, it adds a
large batch of references at once, and keeps count of the ones it hasn't
handed out yet in `pagecnt_bias`, a plain `int` in its own ring state:

| | For each buffer given to the stack | Now and then |
|---|---|---|
| Without a bias | `get_page(page)`: a `lock incl` on the shared count | |
| With a bias | `pagecnt_bias--`: an ordinary decrement | `page_ref_add(page, n)` when the bias runs out |

The commits that added it say so: "to eliminate needing to increment the
atomic page ref count on every pass in the rx hotpath" (58401b2a46e7, GQI),
and "to avoid an atomic increment of pagecount every time we attempt to
reuse a page" (9b8dd5e5ea48, DQO).

The bias also tells gve when a buffer is free again: when
`page_count() == pagecnt_bias`. Reading the count is a plain load, with no
locked instruction either.

The size of the batch only sets how often the refill's `lock addl` runs:
once every 65,535 handouts of a page with `USHRT_MAX`, never in practice
with `INT_MAX`. A few hundred would already make it rare. A bigger batch
buys nothing more, and each reference in it is one fewer for the rest of the
kernel.

## The accounting rule that breaks

So for every RX page, gve keeps two numbers:

- `page->_refcount`, the real kernel refcount.
- `page_info->pagecnt_bias`, the references the driver still holds.

The rule is: **refcount = bias + references held by the stack**. Handing a
buffer to the stack moves one reference from the bias to the stack, so the
refcount does not change. The page is free to reuse when
`refcount == bias` (`gve_rx_can_recycle_buffer()`, gve_rx.c:498).

The bias starts at `INT_MAX`, so the refcount starts at `INT_MAX`. Any
reference the stack takes on its own, with `get_page()`, pushes the refcount
above `INT_MAX`. The counter is a signed 32-bit `atomic_t`, so `INT_MAX + 1`
wraps to `INT_MIN`.

## Step 0: ring allocation puts every page at INT_MAX

Runs at device up, and again on any ring reallocation, such as
`ethtool -G ens4 rx N`.

```
gve_rx_alloc_rings_gqi()                         gve_rx.c:381
└─ gve_rx_prefill_pages()                        gve_rx.c:178
   ├─ data pages:  gve_setup_rx_buffer()         gve_rx.c:144
   │     page_ref_add(page, INT_MAX - 1);        gve_rx.c:152
   │     page_info->pagecnt_bias = INT_MAX;      gve_rx.c:153
   └─ copy pool:                                 gve_rx.c:227-228
         page_ref_add(page, INT_MAX - 1);
         rx->qpl_copy_pool[j].pagecnt_bias = INT_MAX;
```

State of a fresh page: refcount `INT_MAX`, bias `INT_MAX`, stack holds 0.

## Step 1: a packet arrives and gve hands the page to the stack

Softirq context, NAPI poll on the RX queue.

```
gve_napi_poll()                                  gve_main.c:313
└─ gve_rx_poll()                                 gve_rx.c:1080
   └─ gve_clean_rx_done()                        gve_rx.c:998
      └─ gve_rx()                                gve_rx.c:794
         ├─ gve_rx_skb()                         gve_rx.c:646
         │  │  packets <= rx_copybreak are copied into the skb head and
         │  │  never reach this bug                gve_rx.c:655
         │  └─ gve_rx_qpl()                      gve_rx.c:619
         │     ├─ can_flip: zero-copy
         │     │  ├─ gve_rx_add_frags()          gve_rx.c:445
         │     │  │    skb_add_rx_frag(skb, ..., page_info->page, ...)
         │     │  │    no get_page(): the skb takes a reference from the bias
         │     │  └─ gve_dec_pagecnt_bias()      gve_utils.c:92   bias--
         │     └─ else: gve_rx_copy_to_pool()    gve_rx.c:533
         │          memcpy into a copy pool page, then the same
         │          gve_rx_add_frags() + gve_dec_pagecnt_bias()   gve_rx.c:592,597
         └─ napi_gro_frags()                     gve_rx.c:911
            └─ GRO merges consecutive segments into one large skb
               └─ ... tcp_v4_rcv() → tcp_rcv_established()
                  → skb queued on the upstream socket's receive queue
```

State: refcount `INT_MAX`, bias `INT_MAX - 1`, stack holds 1, the skb frag.
Headroom left below `INT_MAX`: **zero**.

The `handoff` probe (see [Measuring it](#measuring-it)) counted 19,673 handoffs at
exactly `INT_MAX` in one stock-driver run of 100 downloads, and none on the
patched driver.

## Step 2: splice(upstream socket → pipe) takes an extra reference

The relay thread `up->client` calls `os.splice(src, pipe_w, 1 MiB)`.

```
__x64_sys_splice()                               fs/splice.c
└─ __do_splice()                                 fs/splice.c:1405
   └─ do_splice()                                fs/splice.c:1308
      │  "out" is a pipe, so take the file-to-pipe branch
      └─ splice_file_to_pipe()                   fs/splice.c:1288
         └─ do_splice_read()                     fs/splice.c:962
            └─ sock_splice_read()                net/socket.c:1085
               └─ tcp_splice_read()              net/ipv4/tcp.c:793
                  └─ tcp_read_sock()             net/ipv4/tcp.c:1649
                     └─ __tcp_read_sock()        net/ipv4/tcp.c:1571
                        └─ tcp_splice_data_recv()              tcp.c:757
                           └─ skb_splice_bits()                skbuff.c:3243
                              └─ __skb_splice_bits()           skbuff.c:3185
                                 │  linear head: not a gve page, gve puts
                                 │  the data in frags.  frags: by reference
                                 └─ __splice_segment()         skbuff.c:3146
                                    └─ spd_fill_page()         skbuff.c:3119
                                         get_page(page);       skbuff.c:3137
                                         ▲ refcount INT_MAX → INT_MAX + 1
                                           = 0x80000000 = INT_MIN
                        └─ splice_to_pipe(): the page now sits in a pipe buffer
```

The pipe holds 16 buffers by default (`PIPE_DEF_BUFFERS`). A GRO skb can carry
up to 64 KiB spread over many pages, in its frags and in chained skbs, so the
pipe often fills partway through an skb. `__tcp_read_sock()` frees an skb with `tcp_eat_recv_skb()` only once all
of its data has been consumed. A partly spliced skb stays on the receive queue
and keeps its reference.

So, while the pipe is waiting to be drained, the page has:

- the skb's reference, from the bias,
- the pipe's extra reference, from `get_page()`.

That gives refcount = `INT_MAX + 1`. If both halves of a 4 KiB page are in
flight, it's `INT_MAX + 2`.

## Step 3: splice(pipe → client socket) rejects the page

The same thread then calls `os.splice(pipe_r, client, n)`.

```
__x64_sys_splice()
└─ __do_splice()                                 fs/splice.c:1405
   └─ do_splice()                                fs/splice.c:1308
      │  "in" is a pipe, so take the pipe-to-file branch
      └─ do_splice_from()                        fs/splice.c:939
         └─ splice_to_socket()                   fs/splice.c:802   (file op .splice_write)
              msg.msg_flags = MSG_SPLICE_PAGES   fs/splice.c:882
            └─ sock_sendmsg()                    fs/splice.c:892 → net/socket.c:737
               └─ tcp_sendmsg()                  net/ipv4/tcp.c:1356
                  └─ tcp_sendmsg_locked()        net/ipv4/tcp.c:1055
                     │  zc = MSG_SPLICE_PAGES    tcp.c:1086-1088
                     └─ skb_splice_from_iter()   tcp.c:1270 → skbuff.c:7292
                        └─ for each page in the pipe:
                             if (WARN_ON_ONCE(!sendpage_ok(page)))   skbuff.c:7324
                                     goto out;   with ret = -EIO
```

`sendpage_ok()` is in include/linux/net.h:320:

```c
static inline bool sendpage_ok(struct page *page)
{
	return !PageSlab(page) && page_count(page) >= 1;
}
```

`page_count()` returns an `int`. It reads `0x80000000` as `-2147483648`, the
check fails, the kernel warns once per boot, and the send fails with `-EIO`.

The compiled code shows the same thing. This is skb_splice_from_iter() in the
running kernel, disassembled from /proc/kcore. Offsets are from the start of
the function:

```
+0x10c  cmpb  $0xf5,0x33(%rdx)      PageSlab(page)?      page_type == slab
+0x110  jne   +0x18a                not slab: go check the refcount
+0x118  ud2                         WARN_ON_ONCE         the RIP in the dmesg trace
+0x11a  mov   $0xfffffffffffffffb,%r14                   ret = -EIO (-5)
...
+0x19f  mov   0x34(%rdx),%edx       EDX = page->_refcount
+0x1a2  test  %edx,%edx             ◀ the "rejected" probe sits here
+0x1a4  jle   +0x112                refcount <= 0: jump to the WARN
+0x1b9  call  skb_append_pagefrags  page accepted
```

That's why every warning shows `RDX: 0000000080000000`. It is the page's
refcount, `INT_MAX + 1`. The `rejected` probe, placed at `+0x1a2`, read it
directly in the same run (see [Measuring it](#measuring-it)):

| refcount at the check | pages rejected |
|---|---|
| 2147483648 = INT_MAX + 1 | 571 |
| 2147483649 = INT_MAX + 2 | 81 |

## Step 4: the error reaches userspace

```
tcp_sendmsg_locked()      returns -EIO, or a short count if it had already
                          queued some bytes; the next call then hits -EIO
splice_to_socket()        returns -EIO
splice(2)                 fails with errno EIO
relay.py pump()           logs "up->client: EIO Input/output error",
                          then shuts down both sockets
curl                      sees the connection close early: a short download
```

More pages are rejected than connections fail, 652 against 138 in the run
above. A connection can retry the send and hit more bad pages before
`splice()` finally returns `EIO`.

## The same overflow, seen by tee()

`tee()` copies a pipe's buffers into another pipe, also by reference. It
takes its references with `try_get_page()`, which refuses a page whose count
isn't positive. `relay.py --tee` tees every chunk before it sends it on:

```
__x64_sys_tee()                                  fs/splice.c:2009
└─ do_tee()                                      fs/splice.c:1970
   └─ link_pipe()                                fs/splice.c:1879
      └─ pipe_buf_get()                          include/linux/pipe_fs_i.h:202
         │  skb_splice_bits() gave the buffer nosteal_pipe_buf_ops
         │                                       skbuff.c:3253, fs/splice.c:411
         └─ generic_pipe_buf_get()               fs/pipe.c:183
            └─ try_get_page()                    include/linux/mm.h:1453
                 if (WARN_ON_ONCE(page_ref_count(page) <= 0))   mm.h:1456
                         return false;
      ret = -EFAULT                              fs/splice.c:1929
```

The kernel logs `WARNING: ... at include/linux/mm.h:1456
generic_pipe_buf_get+0x51/0x60`, and `tee()` fails with `EFAULT`.

That check is older than the bug. It came in 5.1, with 15fab63e1e57 ("fs:
prevent page refcount overflow in pipe_buf_get"), to stop pipes from
overflowing a page's refcount (CVE-2019-11487). So kernels that have gve's
bias but not the step 3 check, from 5.14 (DQO) and 5.16 (GQI) up to 6.4,
fail here too.

## Step 3b (GQI): gve resets the device

There is a worse outcome on GQI than a failed syscall. When gve goes to
reuse a page, it checks the count against the bias:

```
gve_rx_poll()                                    gve_rx.c  (NAPI RX softirq)
  gve_rx_can_recycle_buffer()                    gve_rx.c:498
    pagecount = page_count(page);                # wrapped: negative
    if (pagecount == pagecnt_bias) return 1;     # reuse
    else if (pagecount > pagecnt_bias) return 0; # busy, copy elsewhere
    WARN(pagecount < pagecnt_bias, ...);         gve_rx.c:507
    return -1;
  if (recycle < 0) gve_schedule_reset(priv);     gve_rx.c:551, 671, 978
```

A wrapped `page_count()` is negative, so it's less than the bias: the WARN
fires and gve schedules a device-wide reset, which drops every connection
on the NIC. This runs in the NAPI RX softirq, so the trigger is whatever
pinned the page, not the current receiver. An unprivileged program that
splices received data and holds the pages in `tee()` pipes it never drains
sets it off within seconds. Observed on the stock driver, while other
traffic cycled the ring:

```
Pagecount should never be less than the bias.
WARNING: CPU: 0 ... gve_rx.c:507 gve_rx_can_recycle_buffer+0x58/0x70 [gve]
 gve_rx_poll ... gve_napi_poll ... __napi_poll ... net_rx_action
gve 0000:00:04.0: Performing reset
```

The reset recovers on its own (the link was back within 1-10 s each time),
so it's a transient outage that recurs for as long as the pinning workload
runs; with `panic_on_warn=1` the warning panics the machine. DQO wraps the
refcount the same way but has no reset on its recycle path, only
`EIO`/`EFAULT`. The fix removes the reset: the bias no longer reaches a
value that lets `page_count()` wrap.

## The same bug on DQO-QPL

DQO-QPL hasn't been run, but its buffers take the same path. In `net`:

```
gve_alloc_qpl_page_dqo()                         gve_buffer_mgmt_dqo.c:129
     page_ref_add(page, INT_MAX - 1);            gve_buffer_mgmt_dqo.c:152
     pagecnt_bias = INT_MAX;                     gve_buffer_mgmt_dqo.c:153
gve_rx_dqo()
├─ gve_skb_add_rx_frag()                         gve_rx_dqo.c:589
│    skb_add_rx_frag(...): no get_page()        gve_rx_dqo.c:600
└─ gve_reuse_buffer()                            gve_buffer_mgmt_dqo.c:283
   ├─ gve_dec_pagecnt_bias()                     gve_buffer_mgmt_dqo.c:290
   └─ gve_try_recycle_buf()                      gve_buffer_mgmt_dqo.c:168
        posts the page's next chunk right away, while this one is in an skb
```

A new page's first buffer sits at exactly `INT_MAX`, as on GQI, and the
pipe's `get_page()` wraps it. When it runs low on free buffers, DQO-QPL
copies packets into new pages instead (`gve_rx_copy_ondemand()`,
gve_rx_dqo.c:642), and those have no bias.

gve logs its format when it loads: `GVE queue format 4` is DQO-QPL (1 is
GQI-RDA, 2 GQI-QPL, 3 DQO-RDA). Unlike the others, DQO-QPL gets no "Driver
is running with" line. `reproduce.sh` prints the format by name.

## Why it's intermittent

The refcount doesn't stay at `INT_MAX`. Say gve has handed out H buffers of
a page since it set the page up, O of them are still in skbs, and others
hold E extra references: pipes, socket queues. The bias has gone down by H,
so:

```
refcount = bias + O + E = (INT_MAX - H) + O + E = INT_MAX + E - (H - O)
```

H − O is the number of buffers that have come back. The count wraps when
the extra references outnumber them: E > H − O.

- **A new page** has had nothing back. One `get_page()` while its first
  buffer is in an skb wraps it: the `INT_MAX + 1` in RDX.
- **An older page** has room for one extra reference per buffer that came
  back. But the extra references to its earlier buffers use that room for
  as long as their data sits in a pipe or a socket queue.

The `handoff` probe counted 19,673 handoffs at exactly `INT_MAX`, many more
than the 3,072 pages in the ring (1,024 data pages, 2,048 copy pool pages).
So pages run out of room more than once. But they gain room as they age, and
the failures cluster where the pages are new:

- **Right after boot.** The original warning fired at 13:31, six minutes
  after the VM booted.
- **Right after a ring reallocation.** Resizing the ring with `ethtool -G`
  frees every RX page and allocates new ones.

In one stock run of 200 downloads after a ring reset, the four batches of
50 lost 39, 35, 28 and 6. Across eight such runs, 108 to 147 of 200
failed (53 to 92 completed). On a VM that has been passing traffic for a
while, 200 of 200 complete. That's why `reproduce.sh` resets the ring first.

`WARN_ON_ONCE` prints only the first time. Later failures are silent unless
the warning is re-armed with `echo 1 > /sys/kernel/debug/clear_warn_once`.

## With the fix

The bias starts at `USHRT_MAX`, as in Intel's drivers, and is stored in a
`u16`. A fresh page then sits at refcount `65535`, and the pipe's extra
reference takes it to `65536`.
`page_count()` stays positive, `sendpage_ok()` and `try_get_page()` pass, and
the page gets sent. Both probes record zero hits. (They were measured with the
first version of the fix, `INT_MAX / 2`; the probes don't depend on the bias.)

When the bias runs out, after 65535 handoffs of one page, the fix adds a
whole new bias of references, where the old code filled the count back up
to `INT_MAX`. The next section explains why that matters.

## Why the fix is correct

Passing the test only shows that the symptom is gone. These three rules
make the bias safe whatever the workload does, and the patch keeps each of
them everywhere gve touches the bias. Write B for `GVE_PAGECNT_BIAS`, b for
a page's `pagecnt_bias`, and R for the references everyone else holds:
skbs, pipes, sockets.

**1. The books balance: refcount = b + R.** Every step changes both sides
by the same amount, or moves a reference from one side to the other:

| Step | b | refcount | R |
|---|---|---|---|
| Set up a page: `gve_setup_rx_buffer()`, the copy pool, `gve_alloc_qpl_page_dqo()` | B | 1 + (B − 1) | 0 |
| Hand a buffer to an skb, then `gve_dec_pagecnt_bias()` | −1 | | +1 |
| Anyone's `get_page()` or `put_page()` | | ±1 | ±1 |
| Refill when b reaches 0: `page_ref_add(page, B)` | +B | +B | |
| Free the page: `page_ref_sub(page, b − 1)`, then gve's last `put_page()` | gone | −b | |

So `page_count() == pagecnt_bias` means exactly "nobody else holds the page"
(`gve_rx_can_recycle_buffer()`), and DQO's `page_count() - pagecnt_bias` is
exactly R (`gve_buf_ref_cnt()`).

**2. gve owns a reference to every page it uses: b ≥ 1.** Otherwise the
stack's last `put_page()` would free a page that is still in the ring. b
reaches 0 only inside `gve_dec_pagecnt_bias()`, which refills it on the
spot. The buffer it has just handed out is in an skb that gve hasn't passed
up yet, so the page can't be freed in between.

The old refill set b to `INT_MAX - page_count()`, which is `INT_MAX - R`.
That's at least 1 only while R < B. With B = `INT_MAX`, that always held.
With B = `USHRT_MAX`, it doesn't: the stack can hold more than 65,535
references to one page. Each `tee()` of a pipe that holds the page makes
one more, and a process can keep tens of thousands of pipes open. b would
go negative, the page would be freed while still in the ring, and the free
path's `page_ref_sub(page, b - 1)` would then add references instead of
dropping them. The patch's refill adds B, so b goes from 0 straight to B,
whatever R is. It also no longer reads `page_count()` first, so references
that other CPUs take or drop in between can't throw it off.

**3. gve leaves room for everyone else: b + R ≤ INT_MAX.** b ≤ B, so this
holds while R ≤ INT_MAX − B. With B = `USHRT_MAX`, that's 2,147,418,112
references to one page, which no workload reaches, and which would overflow
any page in the system, gve's or not: that's the case `try_get_page()` is
there for. With B = `INT_MAX`, it held only while R stayed at most the
number of buffers gve had handed out. One reference more, and the count
wrapped.

**`INT_MAX` isn't the `int` version of igb's `USHRT_MAX`.** igb's
`pagecnt_bias` is a `__u16`, so `USHRT_MAX` is the largest bias igb can
store, as `INT_MAX` is for gve's `int`. But rule 3 isn't about the bias's
own field. It's about `page->_refcount`, the same 32-bit int in both
drivers, shared with the whole kernel. igb's narrow field keeps its bias
far below that limit. gve's field is as wide as the count itself, so its
largest value takes the whole count. [call-graph-igb.md](call-graph-igb.md)
has igb's side.

So the patch stores gve's bias in a `u16` too, and the type enforces rule
3. Set the bias back to `INT_MAX` and an `allmodconfig` build stops:

```
error: unsigned conversion from 'int' to 'u16' {aka 'short unsigned int'}
       changes value from '2147483647' to '65535' [-Werror=overflow]
```

**The size of B doesn't affect correctness,** only how often the refill's
`lock addl` runs. B = 1 is the plain approach, one atomic increment per
buffer, which is plainly correct. The patched driver passes the test with
B = 1 too (100 of 100 downloads, with `relay.py --tee`). There,
every handout goes through the refill, which with `USHRT_MAX` runs once per
65,535 handouts of a page.

**What the test can't show.** It never holds more than a few references to
one page, so it can't tell the old refill from the new one: `INT_MAX / 2`
with the old refill passed it too. The refill changed because of rule 2,
not because of a test result.

## Measuring it

Two kprobes, counted with histogram triggers, show the refcounts directly.
They only work on `6.12.113+deb13-cloud-amd64`: the `rejected` offset and the
struct offsets in `handoff` are specific to that build.

The driver must be loaded first, because `handoff` probes a function
inside the gve module. `reproduce.sh` resizes the RX ring itself, so its
pages are fresh when the probes count.

```sh
T=/sys/kernel/tracing
sudo sh -c "echo 'p:gvebug/rejected skb_splice_from_iter+0x1a2 page=%bp:x64 refcount=%dx:u32' >> $T/kprobe_events"
sudo sh -c "echo 'p:gvebug/handoff gve:gve_dec_pagecnt_bias page=+0(%di):x64 refcount=+52(+0(%di)):u32' >> $T/kprobe_events"
sudo sh -c "echo 'hist:keys=refcount if refcount == 0 || refcount >= 2147483648' > $T/events/gvebug/rejected/trigger"
sudo sh -c "echo 'hist:keys=refcount if refcount == 2147483647' > $T/events/gvebug/handoff/trigger"

./reproduce.sh
sudo cat $T/events/gvebug/handoff/hist    # handoffs at refcount INT_MAX
sudo cat $T/events/gvebug/rejected/hist   # refused pages: 2147483648 = INT_MAX + 1
```

Remove them before reloading the driver:

```sh
sudo sh -c "echo '!hist:keys=refcount if refcount == 0 || refcount >= 2147483648' > $T/events/gvebug/rejected/trigger"
sudo sh -c "echo '!hist:keys=refcount if refcount == 2147483647' > $T/events/gvebug/handoff/trigger"
sudo sh -c "echo '-:gvebug/rejected' >> $T/kprobe_events; echo '-:gvebug/handoff' >> $T/kprobe_events"
```
