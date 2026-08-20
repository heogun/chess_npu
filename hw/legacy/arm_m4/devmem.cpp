#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <cerrno>

static int usage() {
    fprintf(stderr, "usage: devmem ADDR [WIDTH [VAL]]   (WIDTH=8/16/32, default 32; read if VAL absent)\n");
    return 1;
}

int main(int argc, char** argv) {
    if (argc < 2) return usage();
    uint32_t addr = (uint32_t)strtoul(argv[1], nullptr, 0);
    unsigned width = 32;
    if (argc >= 3) width = (unsigned)atoi(argv[2]);
    if (width != 8 && width != 16 && width != 32) { fprintf(stderr, "width must be 8/16/32\n"); return 1; }

    int fd = ::open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }
    void* p = mmap(nullptr, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                   (off_t)(addr & ~(uint32_t)0xFFFu));
    if (p == MAP_FAILED) { perror("mmap"); ::close(fd); return 1; }
    ::close(fd);
    unsigned off = addr & 0xFFFu;

    if (argc >= 4) {
        uint32_t val = (uint32_t)strtoul(argv[3], nullptr, 0);
        if (width == 8)  *((volatile uint8_t*)p + off) = (uint8_t)val;
        else if (width == 16) *((volatile uint16_t*)p + off) = (uint16_t)val;
        else                 *((volatile uint32_t*)p + off) = val;
    } else {
        uint32_t val;
        if (width == 8)  val = *((volatile uint8_t*)p + off);
        else if (width == 16) val = *((volatile uint16_t*)p + off);
        else                 val = *((volatile uint32_t*)p + off);
        printf("0x%08X\n", val);
    }
    munmap(p, 4096);
    return 0;
}