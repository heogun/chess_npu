// QEMU TCG plugin: exact execution count per guest instruction address.
// Output, one line per instruction: <addr hex> <count> <disassembly>
// Usage: qemu-arm -plugin libinsn_count.so,out=<file> <program>
#include <glib.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <qemu-plugin.h>

QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;

typedef struct {
    uint64_t addr;
    char*    disas;
} Insn;

typedef struct {
    struct qemu_plugin_scoreboard* counter;
    size_t                         n;
    Insn*                          insns;
} Block;

static GMutex      lock;
static GHashTable* blocks;
static char*       outPath;

// A retranslated block with the same start and length is the same code in this static binary.
static uint64_t block_key(uint64_t pc, size_t n) { return pc ^ ((uint64_t) n << 48); }

static void on_tb_trans(qemu_plugin_id_t id, struct qemu_plugin_tb* tb) {
    const uint64_t pc  = qemu_plugin_tb_vaddr(tb);
    const size_t   n   = qemu_plugin_tb_n_insns(tb);
    const uint64_t key = block_key(pc, n);

    g_mutex_lock(&lock);
    Block* b = g_hash_table_lookup(blocks, (gpointer) key);
    if (!b)
    {
        b          = g_new0(Block, 1);
        b->counter = qemu_plugin_scoreboard_new(sizeof(uint64_t));
        b->n       = n;
        b->insns   = g_new0(Insn, n);
        for (size_t i = 0; i < n; ++i)
        {
            struct qemu_plugin_insn* insn = qemu_plugin_tb_get_insn(tb, i);
            b->insns[i].addr              = qemu_plugin_insn_vaddr(insn);
            b->insns[i].disas             = qemu_plugin_insn_disas(insn);
        }
        g_hash_table_insert(blocks, (gpointer) key, b);
    }
    g_mutex_unlock(&lock);

    qemu_plugin_register_vcpu_tb_exec_inline_per_vcpu(tb, QEMU_PLUGIN_INLINE_ADD_U64,
                                                      qemu_plugin_scoreboard_u64(b->counter), 1);
}

static void write_block(gpointer key, gpointer value, gpointer user) {
    (void) key;
    Block*         b     = value;
    FILE*          f     = user;
    const uint64_t count = qemu_plugin_u64_sum(qemu_plugin_scoreboard_u64(b->counter));
    if (!count)
        return;
    for (size_t i = 0; i < b->n; ++i)
        fprintf(f, "%" PRIx64 " %" PRIu64 " %s\n", b->insns[i].addr, count,
                b->insns[i].disas ? b->insns[i].disas : "?");
}

static void on_exit_cb(qemu_plugin_id_t id, void* unused) {
    FILE* f = fopen(outPath, "w");
    if (!f)
    {
        perror(outPath);
        return;
    }
    g_hash_table_foreach(blocks, write_block, f);
    fclose(f);
}

QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id,
                                           const qemu_info_t* info,
                                           int                argc,
                                           char**             argv) {
    for (int i = 0; i < argc; ++i)
        if (!strncmp(argv[i], "out=", 4))
            outPath = g_strdup(argv[i] + 4);
    if (!outPath)
    {
        fprintf(stderr, "insn_count: out=<file> is required\n");
        return -1;
    }
    blocks = g_hash_table_new(g_direct_hash, g_direct_equal);
    qemu_plugin_register_vcpu_tb_trans_cb(id, on_tb_trans);
    qemu_plugin_register_atexit_cb(id, on_exit_cb, NULL);
    return 0;
}
