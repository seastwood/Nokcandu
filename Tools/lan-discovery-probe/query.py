#!/usr/bin/env python3
"""Read-only GameSpy v1 LAN query, matching Battlefield 1942's observed browse request.

No relaying, firewall changes, configuration writes or full-subnet scans. A reply
proves a query endpoint answered; silence alone cannot identify the failing layer.
"""
import argparse
import ipaddress
import socket
import time


def query(target, ports, timeout):
    replies = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.bind(("", 0))
        sock.settimeout(min(timeout, 0.25))
        for port in ports:
            sock.sendto(b"\\status\\", (target, port))
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            try:
                data, peer = sock.recvfrom(65535)
                replies.append((peer, len(data)))
            except socket.timeout:
                pass
    return replies


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", type=str, help="Explicit IPv4 host or broadcast address")
    parser.add_argument("--timeout", type=float, default=2)
    args = parser.parse_args()
    target = ipaddress.IPv4Address(args.target)
    if not 0 < args.timeout <= 10:
        parser.error("timeout must be greater than 0 and at most 10 seconds")
    # Do not print packet contents (server/player names may be personal).
    replies = query(str(target), range(22000, 22011), args.timeout)
    for peer, size in replies:
        print(f"Reply from {peer[0]}:{peer[1]}: {size} bytes")
    if not replies:
        print("No discovery reply. This does not by itself prove a game, Wine, firewall or network defect.")


if __name__ == "__main__":
    main()
