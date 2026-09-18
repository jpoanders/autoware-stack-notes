#!/usr/bin/env python3
# Minimal RTPS/SPDP decoder: dump submessages and the SPDP DATA parameter list.
import sys, struct, binascii
d=open(sys.argv[1],"rb").read()
assert d[:4]==b'RTPS', "not RTPS"
print(f"len={len(d)} ver={d[4]}.{d[5]} vendor={d[6]:02x}{d[7]:02x} guidprefix={binascii.hexlify(d[8:20]).decode()}")
PID={0x0000:'PAD',0x0001:'SENTINEL',0x0015:'PROTOCOL_VERSION',0x0016:'VENDORID',
0x0031:'DEFAULT_UNICAST_LOCATOR',0x0032:'DEFAULT_MULTICAST_LOCATOR',
0x0033:'METATRAFFIC_UNICAST_LOCATOR',0x0034:'METATRAFFIC_MULTICAST_LOCATOR',
0x0002:'PARTICIPANT_LEASE_DURATION',0x0050:'PARTICIPANT_GUID',
0x0058:'BUILTIN_ENDPOINT_SET',0x0059:'ENDPOINT_GUID',0x005a:'ENDPOINT_GUID_005a',
0x0044:'BUILTIN_ENDPOINT_QOS',0x0077:'DOMAIN_ID',0x0071:'STATUS_INFO',
0x0072:'ADLINK_PARTICIPANT_VERSION_INFO',0x0007:'ADLINK_EXEC_NAME'}
o=20
while o+4<=len(d):
    sid=d[o]; flags=d[o+1]; le = flags & 1
    (nxt,)=struct.unpack('<H' if le else '>H', d[o+2:o+4])
    body_off=o+4
    end = body_off+nxt if nxt else len(d)
    print(f"\nSUBMSG id=0x{sid:02x} flags=0x{flags:02x} le={le} octetsToNext={nxt} body[{body_off}:{end}]")
    if sid==0x15:  # DATA
        # Data submessage: extraFlags(2) octetsToInlineQos(2) readerId(4) writerId(4) writerSN(8) then inlineQos/payload
        eflags,o2iq = struct.unpack('<HH', d[body_off:body_off+4])
        rid=d[body_off+4:body_off+8]; wid=d[body_off+8:body_off+12]
        sn=struct.unpack('<II', d[body_off+12:body_off+20])
        print(f"  DATA extraFlags=0x{eflags:04x} o2iq={o2iq} readerId={binascii.hexlify(rid).decode()} writerId={binascii.hexlify(wid).decode()} SN={sn}")
        # payload starts at body_off+4+o2iq (o2iq measured from start of readerId)
        pl = body_off+4+o2iq
        # SPDP: Data flag D=1 -> serializedData is a parameter list with encapsulation header (4 bytes)
        enc = d[pl:pl+4]; print(f"  encaps={binascii.hexlify(enc).decode()}")
        p = pl+4
        while p+4<=end:
            pid,plen = struct.unpack('<HH', d[p:p+4])
            if pid==0x0001: print(f"    PID SENTINEL @ {p}"); break
            name=PID.get(pid,f'0x{pid:04x}')
            val=d[p+4:p+4+plen]
            extra=''
            if pid in (0x0050,0x0059,0x005a): extra=' guid='+binascii.hexlify(val).decode()
            if pid in (0x0031,0x0032,0x0033,0x0034) and plen>=24:
                kind,port=struct.unpack('<ii', val[0:8]); ip=val[8:24]
                extra=f' kind={kind} port={port} addrtail={binascii.hexlify(ip[-4:]).decode()}'
            if pid==0x0058: extra=' beset='+binascii.hexlify(val).decode()
            print(f"    PID {name} (0x{pid:04x}) len={plen} @off {p}{extra}")
            p += 4 + ((plen+3)&~3)
    o = end
