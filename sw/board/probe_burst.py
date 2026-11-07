# Read-back check of every burst length 1-16 on the F2SDRAM port, through mem_probe CSRs.
# Writes the probe pattern to a 1 MiB window at 0x3C000000 with burst 16, then reads it back
# sequentially with each burst length and reports mismatching beats (BAD).
import mmap, os, struct, sys, time

f = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
csr = mmap.mmap(f, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=0xFF200000)
sdr = mmap.mmap(f, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=0xFFC25000)
wr = lambda r, v: struct.pack_into('<I', csr, 4 * r, v & 0xFFFFFFFF)
rd = lambda r: struct.unpack_from('<I', csr, 4 * r)[0]
portrst = struct.unpack_from('<I', sdr, 0x80)[0] & 0x3FFF
if portrst & 0x133 != 0x133:
    struct.pack_into('<I', sdr, 0x80, portrst | 0x133)
width = rd(22)
beat = 16 if width == 128 else 8
print('ID %08x width %d fpgaportrst %03x -> %03x' % (rd(0), width, portrst, struct.unpack_from('<I', sdr, 0x80)[0] & 0x3FFF))
WIN, BEATS = 0x3C000000, (1 << 20) // beat
SEED = 0x5EED1234


def run(mode, burst, count, verify):
    wr(3, WIN // beat); wr(4, BEATS - 1); wr(5, burst); wr(6, 8); wr(7, count); wr(17, SEED)
    wr(1, 1 | (mode << 2) | (16 if verify else 0))
    t0 = time.time()
    while (rd(2) & 3) != 2:
        if time.time() - t0 > 5:
            wr(1, 2)
            return None
    return rd(16), rd(11), rd(19)


print('write', run(2, 16, BEATS // 16, False))
for b in range(1, 17):
    count = (BEATS - 16) // b  # never wraps inside a burst
    r = run(0, b, count, True)
    print('burst %2d count %6d -> BAD %s beats %s issued %s' % (b, count, *(r if r else ('timeout', '-', '-'))))
