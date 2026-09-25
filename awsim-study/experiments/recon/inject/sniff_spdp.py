#!/usr/bin/env python3
# Capture one SPDP datagram off the loopback discovery multicast group so we have
# a byte-exact Cyclone SPDP template to clone for the forged injector participant.
import socket, struct, sys, time, binascii
GRP="239.255.0.1"; PORT=7400
s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("", PORT))
mreq=struct.pack("4s4s", socket.inet_aton(GRP), socket.inet_aton("127.0.0.1"))
s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
s.settimeout(float(sys.argv[2]) if len(sys.argv)>2 else 8.0)
out=sys.argv[1] if len(sys.argv)>1 else "cap/spdp.bin"
seen=0
try:
  while True:
    data,addr=s.recvfrom(65535)
    if data[:4]==b'RTPS':
      seen+=1
      fn=f"{out}.{seen}"
      open(fn,"wb").write(data)
      print(f"[{seen}] {len(data)}B from {addr} -> {fn}  hdrGUIDpfx={binascii.hexlify(data[8:20]).decode()}")
      if seen>=6: break
except socket.timeout:
  print(f"timeout; captured {seen} RTPS datagrams")
