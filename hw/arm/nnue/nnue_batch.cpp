#include "nnue_batch.h"

#include <cstring>
#include <chrono>
#include <thread>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace nnue {

bool HWBackend::submitAuto(const EvalRequest& r, EvalResult& out, int timeout_ms) {
    static uint32_t seq = 1;
    uint32_t s = seq++;
    if (!submit(r, s))
        return false;
    return pollResult(s, out, timeout_ms);
}



bool UIOBackend::open() {
    if (fd_ >= 0)
        return true;
    fd_ = ::open(dev_.c_str(), O_RDWR | O_SYNC);
    if (fd_ < 0)
        return false;
    void* p = mmap(nullptr, NNUEHW_WINDOW_SIZE, PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd_, 0);
    if (p == MAP_FAILED) {
        ::close(fd_);
        fd_ = -1;
        return false;
    }
    win_ = static_cast<volatile uint32_t*>(p);
    ioctl(fd_, NNUEHW_IOC_START);
    return true;
}

void UIOBackend::close() {
    if (fd_ < 0)
        return;
    ioctl(fd_, NNUEHW_IOC_STOP);
    if (win_)
        munmap(const_cast<uint32_t*>(win_), NNUEHW_WINDOW_SIZE);
    win_ = nullptr;
    ::close(fd_);
    fd_ = -1;
}

bool UIOBackend::submit(const EvalRequest& r, uint32_t seq) {
    if (fd_ < 0 || !win_)
        return false;

    struct nnuehw_desc* d = reinterpret_cast<struct nnuehw_desc*>(
        const_cast<uint32_t*>(win_) + NNUEHW_DESC_BASE / 4 +
        (head_ & NNUEHW_DESC_MASK) * (NNUEHW_DESC_ENTRY_BYTES / 4));

    uint32_t add_frame = (head_ & NNUEHW_FEAT_MASK);
    uint32_t rem_frame = add_frame;
    if (r.n_add) {
        uint32_t* dst = nnuehw_feat_frame(const_cast<uint32_t*>(win_), add_frame);
        memcpy(dst, r.added, r.n_add * sizeof(uint32_t));
    }
    if (r.n_rem) {
        uint32_t* dst = nnuehw_feat_frame(const_cast<uint32_t*>(win_), rem_frame);
        memcpy(dst, r.removed, r.n_rem * sizeof(uint32_t));
    }

    memset(d, 0, sizeof(*d));
    d->magic     = NNUEHW_MAGIC;
    d->mode      = r.mode;
    d->bucket    = r.bucket;
    d->side      = r.side;
    d->n_add     = r.n_add;
    d->n_rem     = r.n_rem;
    d->add_frame = add_frame;
    d->rem_frame = rem_frame;
    d->seq       = seq;
    d->cnt_main0 = r.cnt_main0;
    d->cnt_main1 = r.cnt_main1;
    d->cnt_thr0  = r.cnt_thr0;
    d->cnt_thr1  = r.cnt_thr1;

    head_ = (head_ + 1) & NNUEHW_DESC_MASK;
    *nnuehw_csr(win_, NNUEHW_CSR_DESC_HEAD) = head_;
    return true;
}

bool UIOBackend::pollResult(uint32_t seq, EvalResult& out, int timeout_ms) {
    if (fd_ < 0 || !win_)
        return false;
    auto deadline = std::chrono::steady_clock::now() +
                    std::chrono::milliseconds(timeout_ms);

    for (;;) {
        uint32_t h = *nnuehw_csr(win_, NNUEHW_CSR_RESULT_HEAD);
        while (rtail_ != h) {
            const struct nnuehw_result* res =
                reinterpret_cast<const struct nnuehw_result*>(
                    const_cast<uint32_t*>(win_) + NNUEHW_RESULT_BASE / 4 +
                    (rtail_ & NNUEHW_RESULT_MASK) * (NNUEHW_RESULT_ENTRY_BYTES / 4));
            if (res->seq == seq) {
                out.seq        = res->seq;
                out.psqt       = res->psqt;
                out.positional = res->positional;
                out.status     = res->status;
                return true;
            }
            rtail_ = (rtail_ + 1) & NNUEHW_RESULT_MASK;
        }
        *nnuehw_csr(win_, NNUEHW_CSR_RESULT_TAIL) = rtail_;
        if (std::chrono::steady_clock::now() >= deadline)
            return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}

bool UIOBackend::reset() {
    if (fd_ < 0)
        return false;
    ioctl(fd_, NNUEHW_IOC_RESET);
    head_  = 0;
    rtail_ = 0;
    return true;
}

uint32_t UIOBackend::doneCount() {
    if (!win_)
        return 0;
    return *nnuehw_csr(win_, NNUEHW_CSR_DONE);
}



bool MockBackend::defaultRunner_(const EvalRequest& r, EvalResult& out) {
    out.psqt       = static_cast<int32_t>(r.n_add) * 10 - static_cast<int32_t>(r.n_rem) * 7;
    out.positional = static_cast<int32_t>(r.bucket) * 100 + static_cast<int32_t>(r.side);
    out.status     = NNUEHW_RESULT_OK;
    return true;
}

bool MockBackend::submit(const EvalRequest& r, uint32_t seq) {
    EvalResult res;
    res.seq = seq;
    if (!runner_(r, res))
        return false;
    {
        std::lock_guard<std::mutex> lk(m_);
        results_[seq] = res;
        done_++;
    }
    cv_.notify_all();
    return true;
}

bool MockBackend::pollResult(uint32_t seq, EvalResult& out, int timeout_ms) {
    std::unique_lock<std::mutex> lk(m_);
    auto pred = [&] { return results_.count(seq) != 0; };
    if (timeout_ms < 0) {
        cv_.wait(lk, pred);
    } else {
        cv_.wait_for(lk, std::chrono::milliseconds(timeout_ms), pred);
        if (!pred())
            return false;
    }
    out = results_[seq];
    results_.erase(seq);
    return true;
}

bool MockBackend::reset() {
    std::lock_guard<std::mutex> lk(m_);
    q_.clear();
    results_.clear();
    done_ = 0;
    return true;
}



bool BatchScheduler::start() {
    if (!backend_)
        return false;
    return backend_->open();
}

void BatchScheduler::stop() {
    if (backend_)
        backend_->close();
}

uint32_t BatchScheduler::enqueue(const EvalRequest& r) {
    uint32_t seq;
    {
        std::lock_guard<std::mutex> lk(m_);
        seq = next_seq_++;
        inflight_++;
    }
    if (!backend_->submit(r, seq)) {
        std::lock_guard<std::mutex> lk(m_);
        inflight_--;
        return 0;
    }
    return seq;
}

bool BatchScheduler::waitResult(uint32_t seq, EvalResult& out, int timeout_ms) {
    bool ok = backend_->pollResult(seq, out, timeout_ms);
    if (ok) {
        std::lock_guard<std::mutex> lk(m_);
        inflight_--;
    }
    return ok;
}

}  // namespace nnue