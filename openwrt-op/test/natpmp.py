#!/usr/bin/env python3
"""Minimal NAT-PMP client (RFC 6886) for the miniupnpd regression test.

    natpmp.py GATEWAY map    FIRST_PORT COUNT LIFETIME   # UDP mappings, internal = suggested external
    natpmp.py GATEWAY delete FIRST_PORT COUNT            # lifetime 0 removes them

Prints "ok=N failed=M" and exits 0; the test judges the ruleset, not this tool.
"""
import socket
import struct
import sys

OP_MAP_UDP = 1


def request(sock, gateway, internal, external, lifetime):
    sock.sendto(struct.pack("!BBHHHI", 0, OP_MAP_UDP, 0, internal, external, lifetime), (gateway, 5351))
    while True:
        data, _ = sock.recvfrom(64)
        if len(data) < 16:
            continue
        _ver, op, result, _epoch, iport, _eport, _life = struct.unpack("!BBHIHHI", data[:16])
        if op == 128 + OP_MAP_UDP and iport == internal:
            return result


def main():
    gateway, action, first, count = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    lifetime = int(sys.argv[5]) if action == "map" else 0
    ok = failed = 0
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(3)
        for port in range(first, first + count):
            try:
                result = request(sock, gateway, port, port if lifetime else 0, lifetime)
            except socket.timeout:
                result = -1
            if result == 0:
                ok += 1
            else:
                failed += 1
    print(f"{action} ok={ok} failed={failed}")


if __name__ == "__main__":
    main()
