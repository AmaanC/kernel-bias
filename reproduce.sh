#!/usr/bin/env bash
# reproduce.sh: show the gve RX page refcount bug on a Google Cloud VM with a
# gVNIC interface, with the kernel's own warning in dmesg as the proof.
# See README.md for what it shows and why.
#
#   1. Check this is a gVNIC (gve) VM in an affected queue format.
#   2. Resize the RX ring, so gve allocates fresh RX pages. The bug needs
#      them: a fresh page's refcount is exactly INT_MAX, with no headroom.
#   3. Start relay.py, a TCP proxy that moves data with splice(2).
#   4. Download a file RUNS times through it and count the EIO errors.
#   5. Print the kernel warnings this run produced.
#
# Exit status:
#   1  BUG PRESENT   splice() failed with EIO, or tee() with EFAULT
#   0  NO BUG        every download completed
#   2  INCONCLUSIVE  not a gve VM, a format that can't show it, or setup failed
#
#   ./reproduce.sh                       # the Debian mirror, 200 downloads
#   URL=http://PEER/blob ./reproduce.sh   # a file served by another host
#   RUNS=50 IFACE=ens4 ./reproduce.sh
#   RELAY="relay.py --tee" ./reproduce.sh   # also check tee(); automatic before 6.5
#   PORT=18080 ./reproduce.sh             # if 127.0.0.1:8080 is taken
#
# Needs sudo (for ethtool, dmesg and the kernel log), curl, ethtool and
# python3. The network drops for about a second at the ring resize.
#
# The file must come from another host, over the gve NIC: traffic to the
# VM's own addresses is short-circuited over loopback and never reaches gve.
set -euo pipefail
export PATH=$PATH:/usr/sbin:/sbin
cd "$(dirname "$0")"

RUNS=${RUNS:-200}
URL=${URL:-http://deb.debian.org/debian/dists/bookworm/main/binary-amd64/Packages.xz}
PORT=${PORT:-8080}
REST=${URL#*://}; HOSTPORT=${REST%%/*}
HOST=${HOSTPORT%%:*}; UPORT=${HOSTPORT##*:}; [ "$UPORT" = "$HOSTPORT" ] && UPORT=80
LOG=$(mktemp)
MARK="reproduce.sh: start $(date +%s)"

run() { echo "+ $*"; "$@"; }
die() { echo "INCONCLUSIVE: $*"; exit 2; }

for T in curl ethtool python3 ip; do
  command -v "$T" > /dev/null || die "$T is not installed (apt install curl ethtool python3 iproute2)"
done
sudo -v 2> /dev/null || die "this needs sudo, for ethtool and the kernel log"

echo "== 1. Is this a gVNIC VM, in a queue format that has the bias?"
IFACE=${IFACE:-$(ip route show default | awk '{print $5; exit}')}
[ -n "$IFACE" ] || die "no default route; set IFACE="
KERNEL=$(uname -r)
DRIVER=$(basename "$(readlink "/sys/class/net/$IFACE/device/driver" 2> /dev/null || echo none)")
echo "kernel $KERNEL, $IFACE driven by $DRIVER"
[ "$DRIVER" = gve ] || die "$IFACE uses $DRIVER, not gve. This needs a Google Cloud VM with a gVNIC interface."
# gve logs its queue format as a number when it loads.
FORMAT=$(sudo journalctl -k -b --no-pager 2> /dev/null | grep -o 'GVE queue format [0-9]' | tail -1 | grep -o '[0-9]$' || true)
NEW=$([ "$(printf '%s\n' 6.13 "$KERNEL" | sort -V | head -1)" = 6.13 ] && echo yes || echo no)
case ${FORMAT:-} in
  1) echo "queue format: GQI-RDA, which has the INT_MAX bias" ;;
  2) echo "queue format: GQI-QPL, which has the INT_MAX bias" ;;
  3) echo "queue format: DQO-RDA, which has the bias up to 6.12 and uses page_pool from 6.13"
     [ "$NEW" = no ] || die "DQO-RDA on $KERNEL uses page_pool, so it can't show the bug. Use a GQI VM: N2 or another older machine series." ;;
  4) echo "queue format: DQO-QPL, which has the INT_MAX bias" ;;
  *) echo "queue format: unknown (no 'GVE queue format' line in this boot's kernel log); continuing" ;;
esac
# Before 6.5, splice() into a socket doesn't check the page, so only tee()
# shows the bug: add --tee there.
if [ -z "${RELAY:-}" ]; then
  RELAY=relay.py
  [ "$(printf '%s\n' 6.5 "$KERNEL" | sort -V | head -1)" = 6.5 ] || { RELAY="relay.py --tee"; echo "kernel before 6.5: using relay.py --tee, since only tee() checks the page there"; }
fi

echo
echo "== 2. Resize the RX ring, so gve allocates fresh RX pages"
echo "$MARK" | sudo tee /dev/kmsg > /dev/null        # everything after this line in dmesg is this run
# The kernel prints each of these warnings once per boot. Re-arm them, so this
# run gets its own, if the warning has fired already.
if sudo sh -c 'echo 1 > /sys/kernel/debug/clear_warn_once' 2> /dev/null; then
  echo "+ re-armed the kernel's once-per-boot warnings"
else
  echo "(no debugfs: if the warning already fired this boot, it won't print again; the EIO count still shows the bug)"
fi
RING=$(sudo ethtool -g "$IFACE" | awk '/Current/ {c = 1} c && /^RX:/ {print $2; exit}')
[ -n "$RING" ] || die "ethtool -g $IFACE shows no RX ring size"
run sudo ethtool -G "$IFACE" rx $((RING / 2))
run sudo ethtool -G "$IFACE" rx "$RING"
echo -n "+ waiting for the network"
for _ in $(seq 60); do
  timeout 2 bash -c "exec 3<>/dev/tcp/$HOST/$UPORT" 2> /dev/null && break
  echo -n .; sleep 1
done
echo

echo
echo "== 3. Start the splice() proxy"
IP=$(getent ahostsv4 "$HOST" | awk '{print $1; exit}')
[ -n "$IP" ] || die "can't resolve $HOST"
ss -ltn 2> /dev/null | grep -q ":$PORT " && die "127.0.0.1:$PORT is in use; set PORT= to another port"
echo "+ python3 -u $RELAY $IP:$UPORT $PORT &"
# shellcheck disable=SC2086
python3 -u $RELAY "$IP:$UPORT" "$PORT" > "$LOG" 2>&1 &
RELAY_PID=$!
trap 'kill $RELAY_PID 2> /dev/null || true; rm -f "$LOG"' EXIT
sleep 1
kill -0 $RELAY_PID 2> /dev/null || { cat "$LOG"; die "the relay didn't start"; }

echo
echo "== 4. Download $URL $RUNS times through it"
SIZE=$(curl -sf -m 60 -o /dev/null -w '%{size_download}' "$URL") || die "can't download $URL directly"
echo "full size, downloaded directly: $SIZE bytes"
echo "+ curl --connect-to $HOST:$UPORT:127.0.0.1:$PORT $URL   ($RUNS times)"
OK=0
for i in $(seq "$RUNS"); do
  GOT=$(curl -s -m 60 --connect-to "$HOST:$UPORT:127.0.0.1:$PORT" -o /dev/null -w '%{size_download}' "$URL" || true)
  [ "$GOT" = "$SIZE" ] && OK=$((OK + 1))
  [ $((i % 50)) = 0 ] && echo "  $i downloads, $OK complete"
done
EIO=$(grep -c ': EIO ' "$LOG" || true)
EFAULT=$(grep -c ': EFAULT ' "$LOG" || true)

echo
echo "== 5. Result"
echo "complete downloads:  $OK of $RUNS"
echo "EIO from splice():   $EIO"
case $RELAY in
  *--tee*) echo "EFAULT from tee():   $EFAULT" ;;
  *)       echo "EFAULT from tee():   not checked (RELAY=\"relay.py --tee\" checks it)" ;;
esac
echo "kernel warnings since the ring resize (sudo dmesg):"
# skb_splice_from_iter's warning comes with EIO, generic_pipe_buf_get's with
# EFAULT, gve_rx_can_recycle_buffer's with a device reset. In the first,
# RDX holds the page refcount: 0000000080000000 is INT_MAX + 1, the count
# wrapped negative. See docs/call-graph.md.
WARN=$(sudo dmesg | sed -n "/$MARK/,\$p" | awk '
  /WARNING: .*(generic_pipe_buf_get|gve_rx_can_recycle_buffer)/ {print}
  /WARNING: .*skb_splice_from_iter/ {print; w = 1}
  w && /RDX:/ {print; w = 0}
  /Performing reset/ {print}')
printf '%s\n' "${WARN:-none}" | sed 's/^/  /'
echo
if [ "$EIO" -gt 0 ] || [ "$EFAULT" -gt 0 ]; then
  echo "BUG PRESENT: splice() failed with EIO $EIO times, tee() with EFAULT $EFAULT times."
  echo "For the full traces: sudo dmesg | grep -A20 'skb_splice_from_iter\|generic_pipe_buf_get'"
  exit 1
elif [ "$OK" = "$RUNS" ]; then
  echo "NO BUG: all $RUNS downloads completed."
  exit 0
else
  die "$((RUNS - OK)) downloads failed, but not with EIO or EFAULT. Relay log: $(tail -5 "$LOG")"
fi
