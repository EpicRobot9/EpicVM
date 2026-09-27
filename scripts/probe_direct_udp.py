"""Read-only STUN/NAT reachability probe for a proposed host WebRTC port."""

import socket
import struct
import sys
import time


port = int(sys.argv[1])
magic = 0x2112A442
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.bind(("0.0.0.0", port))
    sock.settimeout(8)
    request = struct.pack("!HHI12s", 0x0001, 0, magic, b"epicvmprobe1")
    sock.sendto(request, ("stun.l.google.com", 19302))
    response, _ = sock.recvfrom(1024)
    length = struct.unpack_from("!H", response, 2)[0]
    offset = 20
    mapped = None
    while offset < 20 + length:
        kind, size = struct.unpack_from("!HH", response, offset)
        value = response[offset + 4 : offset + 4 + size]
        if kind == 0x0020 and len(value) >= 8:
            mapped_port = struct.unpack_from("!H", value, 2)[0] ^ (magic >> 16)
            raw_ip = struct.unpack_from("!I", value, 4)[0] ^ magic
            mapped = socket.inet_ntoa(struct.pack("!I", raw_ip)), mapped_port
            break
        offset += 4 + ((size + 3) // 4) * 4
    if mapped is None:
        raise SystemExit("STUN returned no IPv4 XOR-mapped address")
    print(f"mapped={mapped[0]}:{mapped[1]}", flush=True)
    sock.settimeout(30)
    until = time.monotonic() + 30
    received = False
    while time.monotonic() < until:
        try:
            data, peer = sock.recvfrom(128)
        except socket.timeout:
            break
        if data == b"epicvm-direct-probe":
            print(f"external_probe_received_from={peer[0]}:{peer[1]}", flush=True)
            received = True
            break
    if not received:
        print("external_probe_not_received", flush=True)
