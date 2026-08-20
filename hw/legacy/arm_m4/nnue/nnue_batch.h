/*
 * nnue_batch.h — 배칭 스케줄러 + HW 백엔드 추상화 (M4-SW)
 *
 * ABIs: nnuehw.h (커널/FPGA 계약), SF18 evaluate_hw 패치 (evaluate.cpp)
 */
#ifndef NNUE_BATCH_H
#define NNUE_BATCH_H

#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <condition_variable>
#include <string>
#include <vector>
#include <unordered_map>

#include "nnuehw.h"

namespace nnue {

struct EvalRequest {
    uint32_t       mode;    /* NNUEHW_DESC_MODE_* */
    uint32_t       bucket;  /* 0..7 */
    uint32_t       side;    /* 0=WHITE stm, 1=BLACK stm */
    uint32_t       n_add;
    uint32_t       n_rem;
    uint32_t       cnt_main0;  /* added 목록의 persp0 main 수 */
    uint32_t       cnt_main1;  /* persp1 main 수 */
    uint32_t       cnt_thr0;   /* persp0 threat 수 (small: 0) */
    uint32_t       cnt_thr1;   /* persp1 threat 수 (small: 0) */
    const uint32_t *added;  /* [persp0|persp1|thr0|thr1] 순 목록 — submit() 동안 유효 */
    const uint32_t *removed;
};

struct EvalResult {
    uint32_t seq;
    int32_t  psqt;
    int32_t  positional;
    uint32_t status;
};

class HWBackend {
public:
    virtual ~HWBackend() = default;

    virtual bool            open() = 0;
    virtual void            close() = 0;
    virtual bool            submit(const EvalRequest&, uint32_t seq) = 0;
    virtual bool            pollResult(uint32_t seq, EvalResult&, int timeout_ms) = 0;
    virtual bool            reset() = 0;
    virtual uint32_t        doneCount() = 0;
    virtual const char*     name() const = 0;
    virtual uint32_t        batchHint() const = 0;

    /* seq 인자 생략 시 내부에서 자동 발급해 에코 */
    bool submitAuto(const EvalRequest& r, EvalResult& out, int timeout_ms);
protected:
    std::function<bool(const EvalRequest&, EvalResult&)> runner_;
};

/* 표준 UIO 백엔드 — /dev/uio0 mmap + ioctl + irq 대기 */
class UIOBackend final : public HWBackend {
public:
    explicit UIOBackend(const char* dev = "/dev/uio0") : dev_(dev) {}
    ~UIOBackend() override { close(); }

    bool        open() override;
    void        close() override;
    bool        submit(const EvalRequest&, uint32_t seq) override;
    bool        pollResult(uint32_t seq, EvalResult&, int timeout_ms) override;
    bool        reset() override;
    uint32_t    doneCount() override;
    const char* name() const override { return "uio"; }
    uint32_t    batchHint() const override { return 64; }

    volatile uint32_t* window() const { return win_; }
private:
    std::string             dev_;
    int                     fd_ = -1;
    volatile uint32_t       *win_ = nullptr;
    uint32_t                head_ = 0;
    uint32_t                rtail_ = 0;
};

/* 표준 /dev/mem 백엔드 — UIO 없이 lw 브리지(0xFF200000) 창을 직접 mmap.
 * DE1-SoC 커널(5.11.0-altera) 은 CONFIG_UIO 없음 + STRICT_DEVMEM 비활성 →
 * /dev/mem 으로 물리 창 접근이 가능. irq 는 폴링으로 대체한다. (가중치 로드
 * 주소 NNUEHW_LOAD_* 는 nnuehw.h 계약에 정의됨) */
class DevMemBackend final : public HWBackend {
public:
    DevMemBackend()  { mem_fd_ = -1; load_fd_ = -1; }
    ~DevMemBackend() override { close(); }

    bool        open() override;
    void        close() override;
    bool        submit(const EvalRequest&, uint32_t seq) override;
    bool        pollResult(uint32_t seq, EvalResult&, int timeout_ms) override;
    bool        reset() override;
    uint32_t    doneCount() override;
    const char* name() const override { return "devmem"; }
    uint32_t    batchHint() const override { return 64; }

    volatile uint32_t* window() const { return win_; }

    /* 가중치 로드: 평면(FT/FC/PSQT) 워드 주소 base 에서 n 워드를 스트리밍.
     * src 는 호스트 바이트 버퍼(연속)여야 하며, 각 평면별 데이터 폭은 하드웨어 정의. */
    bool loadWeights(uint32_t plane_base, const void* src, uint32_t n_words);
private:
    int                mem_fd_  = -1;
    int                load_fd_ = -1;
    volatile uint32_t  *win_    = nullptr;
    volatile uint32_t  *load_   = nullptr;   /* s_load 매핑 (LOAD_ADDR/LOAD_DATA) */
    uint32_t           head_    = 0;
    uint32_t           rtail_   = 0;
    bool               started_ = false;
};

/* Mock 백엔드 — 호스트 유닛 테스트용. runner_ 가 실제 평가(스칼라)를 수행 */
class MockBackend final : public HWBackend {
public:
    MockBackend()  { runner_ = defaultRunner_; }
    ~MockBackend() override = default;

    bool        open() override { return true; }
    void        close() override {}
    bool        submit(const EvalRequest&, uint32_t seq) override;
    bool        pollResult(uint32_t seq, EvalResult&, int timeout_ms) override;
    bool        reset() override;
    uint32_t    doneCount() override { return done_; }
    const char* name() const override { return "mock"; }
    uint32_t    batchHint() const override { return 0; }

    void setRunner(std::function<bool(const EvalRequest&, EvalResult&)> f) { runner_ = std::move(f); }
private:
    static bool defaultRunner_(const EvalRequest&, EvalResult&);

    std::vector<EvalRequest>        q_;
    std::mutex                      m_;
    std::condition_variable         cv_;
    uint32_t                        done_ = 0;
    std::unordered_map<uint32_t, EvalResult> results_;
};

/* 배칭 스케줄러 — 스레드 안전 enqueue / 결과 대기.
 * 배치 크기 B(=batchHint) 만큼 쌓이거나 wait 시 즉시 HW submit.
 * FPGA 미가동(SW fallback) 시 evaluate_hw 가 스칼라 경로로 대체된다. */
class BatchScheduler {
public:
    explicit BatchScheduler(std::unique_ptr<HWBackend> backend)
        : backend_(std::move(backend)) {}

    bool             start();
    void             stop();
    HWBackend*       backend() const { return backend_.get(); }

    uint32_t         enqueue(const EvalRequest&);
    bool             waitResult(uint32_t seq, EvalResult&, int timeout_ms);
    uint32_t         inflight() const { return inflight_; }
private:
    std::unique_ptr<HWBackend> backend_;
    uint32_t  next_seq_ = 1;
    uint32_t  inflight_ = 0;
    std::mutex m_;
};

}  // namespace nnue

#endif  // NNUE_BATCH_H