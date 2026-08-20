/*
 * mmio_probe — mmap(/dev/mem) 읽기 프로브 (DE1-SoC)
 *
 *  0xFFC04000  i2c0   (hard IP, 항상 존재)
 *  0xFF200000  fpga 창 (lw bridge, s_hps)
 *  0xFF240000  led_pio (lw bridge, 같은 설계)
 *
 * 각 대상: mmap 성공 여부 + 32비트 읽기 4개를 출력.
 * external abort 가 나면 SIGBUS 로 죽으므로, 신호 핸들러를 설치해
 * abort 위치/주소를 보고하고 다음 대상으로 넘어간다.
 */
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <signal.h>
#include <setjmp.h>
#include <cerrno>

static sigjmp_buf jb;
static volatile uint32_t *crash_addr = nullptr;
static volatile sig_atomic_t crashed = 0;

static void on_bus(int sig, siginfo_t *si, void *) {
    crash_addr = (volatile uint32_t *)(uintptr_t)si->si_addr;
    crashed = 1;
    siglongjmp(jb, 1);
}

struct Target { const char* name; uint32_t phys; uint32_t size; };

int main() {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = on_bus;
    sa.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigaction(SIGBUS, &sa, nullptr);
    sigaction(SIGSEGV, &sa, nullptr);

    const Target targets[] = {
        {"i2c0",     0xFFC04000u, 0x100u},
        {"fpga_win", 0xFF200000u, 0x14000u},
        {"led_pio",  0xFF240000u, 0x10u},
        {"lw_base",  0xFF000000u, 0x1000u},
    };

    for (const auto& t : targets) {
        int fd = ::open("/dev/mem", O_RDWR | O_SYNC);
        if (fd < 0) { printf("%-9s open /dev/mem: %s\n", t.name, strerror(errno)); continue; }
        void* p = mmap(nullptr, t.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, t.phys);
        ::close(fd);
        if (p == MAP_FAILED) {
            printf("%-9s mmap @0x%08X: %s\n", t.name, t.phys, strerror(errno));
            continue;
        }
        crashed = 0;
        int r = sigsetjmp(jb, 1);
        if (r == 0) {
            volatile uint32_t* w = (volatile uint32_t*)p;
            for (int i = 0; i < 4; i++) {
                uint32_t v = w[i];
                printf("%-9s @0x%08X +0x%02X = 0x%08X\n", t.name, t.phys, i*4, v);
            }
            printf("%-9s OK\n", t.name);
        } else {
            printf("%-9s ABORT/SEGV at +0x%02X (fault @%p)\n", t.name,
                   (unsigned)((uintptr_t)crash_addr - (uintptr_t)p),
                   (const void*)crash_addr);
        }
        munmap(p, t.size);
    }
    return 0;
}