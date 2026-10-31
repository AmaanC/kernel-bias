#!/usr/bin/env python3
"""relay.py: a TCP proxy that moves data with splice(2), to reproduce the
gve RX page refcount bug (see README.md and patches/).

It listens on 127.0.0.1:LISTEN_PORT and forwards each connection to
UPSTREAM_IP[:PORT] (port 80 by default). Both directions are copied the way
Go's (*net.TCPConn).ReadFrom does it on Linux: splice(socket -> pipe), then
splice(pipe -> socket), so received pages travel by reference and are never
copied. On an affected gVNIC VM the second splice() fails with EIO for
pages whose refcount has wrapped. Every error is printed, one per line:

    up->client: EIO Input/output error

usage: relay.py UPSTREAM_IP[:PORT] LISTEN_PORT [--tee] [--copy]
  --tee   also tee(2) each chunk into a spare pipe, then discard that copy.
          tee() refuses a page with a wrapped refcount (EFAULT) on any kernel
          with the bias, while splice() into a socket only checks the page
          from 6.5 on. A failed tee() is logged; the chunk is still sent on.
  --copy  copy with recv() and send() instead of splice(), as a control:
          no page references are taken, so the bug cannot show.

Python 3.6 or newer. Before 3.10 (RHEL 9, SLES 15) os.splice() is missing,
so libc's splice() is called through ctypes.
"""
import ctypes
import errno
import os
import socket
import sys
import threading

if len(sys.argv) < 3 or sys.argv[1].startswith("-"):
    sys.exit("usage: " + __doc__.split("usage: ", 1)[1].rstrip())

UP, PORT = sys.argv[1], int(sys.argv[2])
UP_HOST, _, UP_PORT = UP.partition(":")
UP_PORT = int(UP_PORT or 80)
TEE = "--tee" in sys.argv
COPY = "--copy" in sys.argv
CHUNK = 1 << 20
libc = ctypes.CDLL(None, use_errno=True)


def libc_call(name, *args):
    got = getattr(libc, name)(*args)
    if got < 0:
        e = ctypes.get_errno()
        raise OSError(e, f"{name}: {os.strerror(e)}")
    return got


if not hasattr(os, "splice"):
    os.splice = lambda src, dst, n: libc_call(
        "splice", src, None, dst, None, ctypes.c_size_t(n), 0)


def log(tag, e):
    print(f"{tag}: {errno.errorcode.get(e.errno, e.errno)} {e.strerror}", flush=True)


def pump(src, dst, tag):
    """Copy src to dst until EOF or an error, then shut both sockets down,
    so that the first direction to end tears down the whole connection."""
    try:
        if COPY:
            while True:
                b = src.recv(CHUNK)
                if not b:
                    break
                dst.sendall(b)
            return
        r, w = os.pipe()
        spare_r, spare_w = os.pipe()
        null = os.open(os.devnull, os.O_WRONLY)
        try:
            while True:
                n = os.splice(src.fileno(), w, CHUNK)   # socket -> pipe
                if n == 0:
                    break
                if TEE:
                    try:
                        t = libc_call("tee", r, spare_w, ctypes.c_size_t(n), 0)
                        while t:
                            t -= os.splice(spare_r, null, t)
                    except OSError as e:
                        log(tag, e)
                while n:
                    n -= os.splice(r, dst.fileno(), n)   # pipe -> socket
        finally:
            for fd in (r, w, spare_r, spare_w, null):
                os.close(fd)
    except OSError as e:
        log(tag, e)
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle(client):
    upstream = socket.create_connection((UP_HOST, UP_PORT))
    t = threading.Thread(target=pump, args=(client, upstream, "client->up"), daemon=True)
    t.start()
    pump(upstream, client, "up->client")
    t.join()
    client.close()
    upstream.close()


listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", PORT))
listener.listen(64)
mode = "copy" if COPY else "splice+tee" if TEE else "splice"
print(f"relay {mode} 127.0.0.1:{PORT} -> {UP_HOST}:{UP_PORT}", flush=True)
while True:
    conn, _ = listener.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
