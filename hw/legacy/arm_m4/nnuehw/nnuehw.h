/*
 * nnuehw.h — NNUE 가속기 HPS↔FPGA ABI (M4-SW)
 *
 * 커널 드라이버(nnuehw.ko)와 사용자 공간(nnue_batch.cpp)이 공유하는 단일 계약.
 * FPGA-Top RTL은 이 헤더가 정의한 레이아웃/레지스터/포맷을 그대로 구현한다.
 *
 * 메모리 창 (단일 연속 영역, UIO map 0 으로 mmap; lw bridge 상 물리주소는 DT 'reg')
 * ┌────────┬──────────────────────────────────────────────┐
 * │ 0x0000 │ CSR (32b 레지스터 10개)                         │
 * │ 0x0040 │ descriptor ring : 64 × 64B  = 4096B            │
 * │ 0x1040 │ feature area    : 64 frame × 1024B = 65536B    │
 * │ 0x11040│ result ring     : 256 × 16B  = 4096B           │
 * │ 0x12040│ (여유) 전체 창 크기 0x14000                      │
 * └────────┴──────────────────────────────────────────────┘
 *
 * 흐름 (v1):
 *  HPS: feature frame 에 index 목록 기록 → descriptor ring[head] 에 기술 →
 *       CSR.DESC_HEAD 갱신 (doorbell) → 필요시 irq
 *  FPGA: DESC_TAIL..HEAD 구간 소비 → FTE 어큐뮬레이터 갱신 + quantize +
 *       FC 파이프라인 → result ring[RESULT_HEAD] 에 결과 기록 → DONE 증가 →
 *       IRQ_STATUS.RESULT_AVAIL set → (IRQ_EN 이면) irq 발생
 *  HPS: IRQ/폴링으로 RESULT_HEAD 변화 감지 → RESULT_TAIL 갱신 후 수거
 *
 * seq 는 요청-응답을 짝짓는 유일 키. 결과 status==0 이면 유효.
 */
#ifndef NNUEHW_H
#define NNUEHW_H

#ifdef __KERNEL__
#include <linux/types.h>
typedef u32 nnuehw_u32;
typedef s32 nnuehw_s32;
#else
#include <stdint.h>
typedef uint32_t nnuehw_u32;
typedef int32_t nnuehw_s32;
#endif

#define NNUEHW_DEVNAME     "nnuehw"
#define NNUEHW_MAGIC       0x4E4E5545u /* "NNUE" */

/* ---- 창 레이아웃 (32b 워드 오프셋) ---- */
#define NNUEHW_CSR_BASE        0x0000u
#define NNUEHW_DESC_BASE       0x0040u
#define NNUEHW_FEAT_BASE       0x1040u
#define NNUEHW_RESULT_BASE     0x11040u
#define NNUEHW_WINDOW_SIZE     0x14000u

/* ---- 링 크기 (전부 2의 거듭제곱) ---- */
#define NNUEHW_DESC_ENTRIES    64u
#define NNUEHW_RESULT_ENTRIES  256u
#define NNUEHW_FEAT_ENTRIES    64u            /* feature frame 수 */
#define NNUEHW_FEAT_FRAME_WORDS 256u          /* frame 당 u32 수 (1KB) */
#define NNUEHW_DESC_ENTRY_BYTES 64u
#define NNUEHW_RESULT_ENTRY_BYTES 16u

#define NNUEHW_DESC_MASK    (NNUEHW_DESC_ENTRIES - 1u)
#define NNUEHW_RESULT_MASK  (NNUEHW_RESULT_ENTRIES - 1u)
#define NNUEHW_FEAT_MASK    (NNUEHW_FEAT_ENTRIES - 1u)

/* ---- 가중치 로드 (s_load, h2f 브리지) 레지스터 맵 ---- */
#define NNUEHW_LOAD_BASE       0xC0100000u   /* s_load 물리 주소 (h2f bridge) */
#define NNUEHW_LOAD_ADDR_REG   0x00u         /* LOAD_ADDR : 평면 워드 주소 베이스 */
#define NNUEHW_LOAD_DATA_REG   0x04u         /* LOAD_DATA : 32b 데이터, 기록 후 주소+1 */
#define NNUEHW_LOAD_PLANE_FT   0x00000000u   /* 워드 주소 [31:28] 대상 선택 */
#define NNUEHW_LOAD_PLANE_FC   0x10000000u
#define NNUEHW_LOAD_PLANE_PSQT 0x20000000u

/* ---- CSR 오프셋 ---- */
#define NNUEHW_CSR_VERSION      0x00u /* R  : 0x4E4E5545 */
#define NNUEHW_CSR_CONTROL      0x04u /* RW : bit0 START, bit1 RESET, bit2 IRQ_EN */
#define NNUEHW_CSR_STATUS       0x08u /* R  : bit0 READY, bit1 BUSY, bit2 FAULT */
#define NNUEHW_CSR_DESC_HEAD    0x0Cu /* RW : HPS 생산자 인덱스 (doorbell) */
#define NNUEHW_CSR_DESC_TAIL    0x10u /* R  : FPGA 소비 인덱스 */
#define NNUEHW_CSR_RESULT_HEAD  0x14u /* R  : FPGA 생산 인덱스 */
#define NNUEHW_CSR_RESULT_TAIL  0x18u /* RW : HPS 소비 인덱스 */
#define NNUEHW_CSR_DONE         0x1Cu /* R  : 완료 누계 (단조 증가) */
#define NNUEHW_CSR_IRQ_STATUS   0x20u /* R  : bit0 RESULT_AVAIL, bit1 FAULT */
#define NNUEHW_CSR_IRQ_ACK      0x24u /* W  : 해당 bit 쓰면 클리어 */

#define NNUEHW_CTRL_START    (1u << 0)
#define NNUEHW_CTRL_RESET    (1u << 1)
#define NNUEHW_CTRL_IRQ_EN   (1u << 2)

#define NNUEHW_STAT_READY    (1u << 0)
#define NNUEHW_STAT_BUSY     (1u << 1)
#define NNUEHW_STAT_FAULT    (1u << 2)

#define NNUEHW_IRQ_RESULT_AVAIL (1u << 0)
#define NNUEHW_IRQ_FAULT        (1u << 1)

#ifdef __KERNEL__
#define NNUEHW_DESC_SIZE_CHECK \
    extern char nnuehw_desc_size_check[sizeof(struct nnuehw_desc) == NNUEHW_DESC_ENTRY_BYTES ? 1 : -1]
#define NNUEHW_RESULT_SIZE_CHECK \
    extern char nnuehw_result_size_check[sizeof(struct nnuehw_result) == NNUEHW_RESULT_ENTRY_BYTES ? 1 : -1]
#else
#include <assert.h>
#define NNUEHW_DESC_SIZE_CHECK \
    static_assert(sizeof(struct nnuehw_desc) == NNUEHW_DESC_ENTRY_BYTES, "desc size")
#define NNUEHW_RESULT_SIZE_CHECK \
    static_assert(sizeof(struct nnuehw_result) == NNUEHW_RESULT_ENTRY_BYTES, "result size")
#endif

/* ---- descriptor (64B) ---- */
#define NNUEHW_DESC_MODE_ACCUMULATE 0u
#define NNUEHW_DESC_MODE_REFRESH     1u

/*
 * feature frame 레이아웃 (REFRESH v1; add_frame 하나로 통합)
 *   persp0/1 은 고정색 (0=WHITE, 1=BLACK) — SF collect_active 순서와 동일.
 *   side(=stm) 는 fpga 내부에서 psqt 선택/출력 순서에만 사용.
 *   [0 .. cnt_main0-1]                     : persp0 main feature 인덱스
 *   [cnt_main0 .. cnt_main0+cnt_main1-1]   : persp1 main
 *   [+ cnt_thr0-1]                         : persp0 threat (big 만; small 은 0)
 *   [+ cnt_thr1-1]                         : persp1 threat (big 만)
 *   n_add == cnt_main0+cnt_main1+cnt_thr0+cnt_thr1 <= 256 (frame 용량)
 *   n_rem == 0 (REFRESH 모드; ACCUMULATE 는 FPGA v1 미지원 → ERR_FAULT)
 */
struct nnuehw_desc {
    nnuehw_u32 magic;      /* NNUEHW_MAGIC */
    nnuehw_u32 mode;       /* ACCUMULATE | REFRESH */
    nnuehw_u32 bucket;     /* 0..7 */
    nnuehw_u32 side;       /* stm: 0=WHITE, 1=BLACK (perspective) */
    nnuehw_u32 n_add;      /* add frame 의 유효 인덱스 수 (== cnt 합) */
    nnuehw_u32 n_rem;      /* rem frame 의 유효 인덱스 수 (REFRESH: 0) */
    nnuehw_u32 add_frame;  /* feature area frame idx (전체 목록) */
    nnuehw_u32 rem_frame;  /* feature area frame idx (미사용, v1) */
    nnuehw_u32 seq;        /* 응답 짝짓기 키 — result 로 에코 */
    nnuehw_u32 cnt_main0;  /* persp0 main feature 수 */
    nnuehw_u32 cnt_main1;  /* persp1 main feature 수 */
    nnuehw_u32 cnt_thr0;   /* persp0 threat feature 수 (small: 0) */
    nnuehw_u32 cnt_thr1;   /* persp1 threat feature 수 (small: 0) */
    nnuehw_u32 pad[3];     /* 향후 확장 예약 */
};
NNUEHW_DESC_SIZE_CHECK;

/* ---- result entry (16B) ---- */
#define NNUEHW_RESULT_OK      0u
#define NNUEHW_RESULT_ERR_BUSY 1u
#define NNUEHW_RESULT_ERR_FAULT 2u

struct nnuehw_result {
    nnuehw_u32 seq;
    nnuehw_s32 psqt;        /* psqt (stm 관점, SF 와 동일 의미) */
    nnuehw_s32 positional;  /* FC 파이프라인 출력 (stm 관점) */
    nnuehw_u32 status;
};
NNUEHW_RESULT_SIZE_CHECK;

/* ---- 상태 스냅샷 (ioctl GET_STATUS) ---- */
struct nnuehw_status {
    nnuehw_u32 version;
    nnuehw_u32 control;
    nnuehw_u32 status;
    nnuehw_u32 desc_head;
    nnuehw_u32 desc_tail;
    nnuehw_u32 result_head;
    nnuehw_u32 result_tail;
    nnuehw_u32 done;
    nnuehw_u32 irq_status;
    nnuehw_u32 batch_size; /* 드라이버가 기억하는 힌트 (ioctl SET_BATCH) */
};

/* ---- ioctl ---- */
#if defined(__linux__)
#include <linux/ioctl.h>
#elif defined(__APPLE__) || !defined(__KERNEL__)
#include <stddef.h>
#define _IO(t, n)             (((t) << 8) | (n))
#define _IOW(t, n, s)         ((1u << 30) | ((sizeof(s) & 0x3fff) << 16) | ((t) << 8) | (n))
#define _IOR(t, n, s)         ((2u << 30) | ((sizeof(s) & 0x3fff) << 16) | ((t) << 8) | (n))
#endif

#define NNUEHW_IOC_MAGIC 0xEE
#define NNUEHW_IOC_RESET      _IO(NNUEHW_IOC_MAGIC, 0)
#define NNUEHW_IOC_START      _IO(NNUEHW_IOC_MAGIC, 1)
#define NNUEHW_IOC_STOP       _IO(NNUEHW_IOC_MAGIC, 2)
#define NNUEHW_IOC_SET_BATCH  _IOW(NNUEHW_IOC_MAGIC, 3, nnuehw_u32)
#define NNUEHW_IOC_GET_STATUS _IOR(NNUEHW_IOC_MAGIC, 4, struct nnuehw_status)

/* ---- feature frame 접근 헬퍼 (사용자 공간) ---- */
#ifndef __KERNEL__
static inline nnuehw_u32 *nnuehw_feat_frame(nnuehw_u32 *win, nnuehw_u32 frame) {
    return win + (NNUEHW_FEAT_BASE / 4u) + (frame & NNUEHW_FEAT_MASK) * NNUEHW_FEAT_FRAME_WORDS;
}

static inline volatile nnuehw_u32 *nnuehw_csr(volatile nnuehw_u32 *win, nnuehw_u32 off) {
    return win + off / 4u;
}
#endif

/* ---- DT 호환 문자열 (드라이버/설계 참조) ---- */
#define NNUEHW_DT_COMPAT "nnue,nnue-hw-1.0"

#endif /* NNUEHW_H */