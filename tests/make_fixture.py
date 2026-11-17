"""Writes a made-up but well-formed set of ATA pages (IDENTIFY DEVICE, SMART READ DATA,
SMART READ THRESHOLDS) for the decoder check. No real drive's data is in here.

    usage: make_fixture.py <output directory>
"""
import struct, sys, os
out = sys.argv[1]
def atastr(s, n):
    b = s.ljust(n).encode()
    return b''.join(bytes([b[i+1], b[i]]) for i in range(0, n, 2))
idw = bytearray(512)
def setw(i, v): struct.pack_into('<H', idw, i*2, v)
idw[20:40] = atastr('TESTSERIAL0001', 20)
idw[46:54] = atastr('FW01', 8)
idw[54:94] = atastr('TESTDISK FIXTURE 8TB', 40)
setw(49, 0x2f00); setw(82, 0x746b); setw(83, 0x7d69); setw(84, 0x61e3)
setw(85, 0x7469); setw(86, 0xbc49); setw(87, 0x61e3)
lba = 15628053168
for k in range(4): setw(100+k, (lba >> (16*k)) & 0xffff)
setw(60, 0xffff); setw(61, 0x0fff)
setw(106, 0x6003); setw(217, 7200)
setw(80, 0x07f0); setw(108, 0x5000); setw(109, 0xcca2); setw(110, 0x1234); setw(111, 0x5678)
attrs = [  # id, flags, value, worst, raw(6 bytes int), thresh
 (1,0x000b,100,100,0,16),(3,0x0007,131,100,(450<<16)|433,24),(4,0x0012,100,100,512,0),
 (5,0x0033,100,100,24,5),(7,0x000b,100,100,0,67),(9,0x0012,94,94,43210,0),
 (10,0x0013,100,100,0,60),(12,0x0032,100,100,498,0),(187,0x0032,98,98,2,0),
 (192,0x0032,100,100,900,0),(193,0x0012,100,100,900,0),
 (194,0x0002,171,171,35|(20<<16)|(52<<32),0),(196,0x0032,100,100,24,0),
 (197,0x0022,100,100,8,0),(198,0x0008,100,100,0,0),(199,0x000a,200,200,3,0)]
d = bytearray(512); t = bytearray(512)
struct.pack_into('<H', d, 0, 16); struct.pack_into('<H', t, 0, 16)
for i,(aid,fl,v,w,raw,th) in enumerate(attrs):
    o = 2+12*i
    d[o]=aid; struct.pack_into('<H', d, o+1, fl); d[o+3]=v; d[o+4]=w
    d[o+5:o+11] = raw.to_bytes(6,'little')
    t[o]=aid; t[o+1]=th
for p in (d,t):
    p[511] = (-sum(p[:511])) & 0xff
open(os.path.join(out,'identify.bin'),'wb').write(idw)
open(os.path.join(out,'smart-data.bin'),'wb').write(d)
open(os.path.join(out,'smart-thresholds.bin'),'wb').write(t)
open(os.path.join(out,'health.txt'),'w').write('passed\n')
