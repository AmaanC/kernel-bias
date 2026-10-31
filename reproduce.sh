#!/usr/bin/env bash
# reproduce.sh: show the gve RX page refcount bug on a Google Cloud VM with a
# gVNIC interface. See README.md for what it shows and why.
#
#   1. Resize the RX ring, so gve allocates fresh RX pages. The bug needs
#      them: a fresh page's refcount is exactly INT_MAX, with no headroom.
#   2. Start relay.py, a TCP proxy that moves data with splice(2).
#   3. Download a file RUNS times through it and count the EIO errors.
#
# Exit status: 1 if splice() failed with EIO (or tee() with EFAULT) at
# least once, so the bug is present; 0 if every download completed.
#
#   sudo ./reproduce.sh                 # the Debian mirror, 200 downloads
#   URL=http://PEER/blob ./reproduce.sh  # a file served by another host
#   RUNS=50 IFACE=ens4 ./reproduce.sh
#   RELAY="relay.py --tee" ./reproduce.sh   # also catch tee()'s EFAULT (< 6.5)
#
# The file must come from another host, over the gve NIC: traffic to the
# VM's own addresses is short-circuited over loopback and never reaches gve.
set -euo pipefail
export PATH=$PATH:/usr/sbin:/sbin
cd "$(dirname "$0")"

RUNS=${RUNS:-200}
URL=${URL:-http://deb.debian.org/debian/dists/bookworm/main/binary-amd64/Packages.xz}
RELAY=${RELAY:-relay.py}
PORT=8080
REST=${URL#*://}; HOSTPORT=${REST%%/*}
HOST=${HOSTPORT%%:*}; UPORT=${HOSTPORT##*:}; [ "$UPORT" = "$HOSTPORT" ] && UPORT=80
IFACE=${IFACE:-$(ip route show default | awk '{print $5; exit}')}
LOG=$(mktemp)

run() { echo "+ $*"; "$@"; }

echo "kernel: $(uname -r), $IFACE: $(basename "$(readlink "/sys/class/net/$IFACE/device/driver")")"
FORMAT=$(sudo journalctl -k -b --no-pager 2>/dev/null | grep -o 'GVE queue format [0-9]' | tail -1 | grep -o '[0-9]$' || true)
case ${FORMAT:-} in
  1) echo "queue format: GQI-RDA (affected)" ;;
  2) echo "queue format: GQI-QPL (affected)" ;;
  3) echo "queue format: DQO-RDA (affected up to 6.12; page_pool, unaffected, from 6.13)" ;;
  4) echo "queue format: DQO-QPL (affected)" ;;
  *) echo "queue format: unknown (no 'GVE queue format' line in the kernel log)" ;;
esac

echo "== 1. Resize the RX ring, so gve allocates fresh RX pages"
run sudo sh -c 'echo 1 > /sys/kernel/debug/clear_warn_once' 2>/dev/null || true   # re-arm WARN_ON_ONCE
RING=$(sudo ethtool -g "$IFACE" | awk '/Current/ {c = 1} c && /^RX:/ {print $2; exit}')
run sudo ethtool -G "$IFACE" rx $((RING / 2))
run sudo ethtool -G "$IFACE" rx "$RING"
for _ in $(seq 60); do
  timeout 2 bash -c "exec 3<>/dev/tcp/$HOST/$UPORT" 2>/dev/null && break
  sleep 1
done

echo "== 2. Start the splice() proxy"
IP=$(getent ahostsv4 "$HOST" | awk '{print $1; exit}')
echo "+ python3 -u $RELAY $IP:$UPORT $PORT &"
# shellcheck disable=SC2086
python3 -u $RELAY "$IP:$UPORT" "$PORT" > "$LOG" 2>&1 &
RELAY_PID=$!
trap 'kill $RELAY_PID 2>/dev/null; rm -f "$LOG"' EXIT
sleep 1
kill -0 $RELAY_PID 2>/dev/null || { cat "$LOG"; exit 2; }

echo "== 3. Download $URL $RUNS times through it"
SIZE=$(curl -sf -m 60 -o /dev/null -w '%{size_download}' "$URL")
OK=0
for i in $(seq "$RUNS"); do
  GOT=$(curl -s -m 60 --connect-to "$HOST:$UPORT:127.0.0.1:$PORT" -o /dev/null -w '%{size_download}' "$URL" || true)
  [ "$GOT" = "$SIZE" ] && OK=$((OK + 1))
  [ $((i % 50)) = 0 ] && echo "  $i downloads, $OK complete"
done
EIO=$(grep -c ': EIO ' "$LOG" || true)
EFAULT=$(grep -c ': EFAULT ' "$LOG" || true)

echo "== Result"
echo "complete downloads:  $OK of $RUNS"
echo "EIO from splice():   $EIO"
case $RELAY in
  *--tee*) echo "EFAULT from tee():   $EFAULT" ;;
  *)       echo "EFAULT from tee():   not checked (RELAY=\"relay.py --tee\" checks it)" ;;
esac
echo "kernel warnings:"
sudo dmesg | grep -E 'WARNING: .*(skb_splice_from_iter|generic_pipe_buf_get|gve_rx_can_recycle_buffer)|RDX:|Performing reset' | head -8 | sed 's/^/  /' || true
if [ "$EIO" -gt 0 ] || [ "$EFAULT" -gt 0 ]; then
  echo "BUG PRESENT: splice() failed with EIO $EIO times, tee() with EFAULT $EFAULT times."
  exit 1
fi
echo "NO BUG: all $RUNS downloads completed."
