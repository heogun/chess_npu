# NNUE 가속기 — HW/SW 인터페이스 명세 (v2.0)

> DE1-SoC NNUE 가속 IP와 Linux HPS 소프트웨어 사이의 계약서.
> 단일 권위 소스: `hw/arm/nnuehw/nnuehw.h` (커널 드라이버·RTL·사용자 공간 공유).
> 설계 근거: `docs/DESIGN.md`

---

## 1. 개요

- HW: FPGA 내 NNUE 가속 IP (`fpga_top_soc.sv`, 윈도우 `hw/quartus/ip/fpga_top_soc`).
- SW: `/dev/mem` 기반 `DevMemBackend` (`nnue_batch.cpp`) 가 CSR·링·가중치 로드를 직접 mmap.
- 비동기 요청/결과는 **차가운 링(descriptor ring / result ring)** 으로 전달. IRQ 없음 → 1ms 폴링.

```
ARM (Stockfish)                     FPGA
  evaluate_hw()                       NNUE IP
   ├─ feature frame 기록               ├─ 디스크립터 링 poll
   ├─ descriptor enqueue + DESC_HEAD   ├─ FT+FC 계산
   └─ RESULT_HEAD/DONE 폴링            └─ result 기록 + DONE 증가
```

키 확정 사항:
- **UIO 커널 드라이버 포기**: 커널 `5.11.0-altera` 에 `CONFIG_UIO` 부재, 재빌드 리스크 대비 부적합.
  `CONFIG_STRICT_DEVMEM` 비활성 → `/dev/mem` full 32-bit physical access 가능.
- 가중치 로드는 lw 창이 아닌 **`s_load` (h2f 풀 브리지)** 레지스터로 스트리밍.

---

## 2. 물리 주소 맵 (권위)

| 구역 | 물리 주소 | 크기 | 오프셋 의미 |
|---|---|---|---|
| lw 브리지 창 `s_hps` | `0xFF200000` | `0x40000`(창 해석 18bit) | fpga_top_soc 윈도우 = offset `0x0` 부터 |
| 가속기 창 (CSR+링+feature) | `0xFF200000` | `0x14000` | `fpga_top_soc.window` |
| led_pio | `0xFF240000` | `0x10` | fpga_top_soc offset `0x40000` |
| **가중치 로드 `s_load`** | `0xC0100000` | `0x100` | fpga_top_soc offset `0x100000` (풀 h2f 브리지) |
| FT DDR (big net) | `0x35000000` | int16 단위 | `ddr_stream` f2h 경로 (M2) |
| PSQT DDR | `0x34000000` | int32 단위 | `ddr_stream` f2h 경로 (M2) |

> soc_system.xml 의 `0x00100000` 평면 오프셋은 onchip_memory2 가 아니라 **s_load**,
> `0x00040000` 은 led_pio 에 해당. `soc_system.html` + twin router 뷰(`mm_interconnect_1_router.sv`) 대조 완료.

---

## 3. 가속기 창 레이아웃 (lw `0xFF200000`, 32-bit 워드)

| 워드 오프셋 | 바이트 오프셋 | 내용 |
|---|---|---|
| `0x0000` | 0x0000 | CSR — 레지스터 10개 (아래 §4) |
| `0x0040` | 0x0040 | descriptor ring: `64 × 64B` = 4096B |
| `0x1040` | 0x1040 | feature area: `64 frame × 1024B` = 65536B |
| `0x11040` | 0x11040 | result ring: `256 × 16B` = 4096B |
| —        | 0x12040…0x14000 | 예약 (전체 창 `NNUEHW_WINDOW_SIZE = 0x14000`) |

상수: `NNUEHW_DESC_ENTRIES=64`, `NNUEHW_RESULT_ENTRIES=256`, `NNUEHW_FEAT_ENTRIES=64`,
`NNUEHW_FEAT_FRAME_WORDS=256`(frame 1KB).

---

## 4. CSR 맵 (창 오프셋, lw `0xFF200000` + offset)

| 오프셋 | 이름 | RW | 설명 |
|---|---|---|---|
| 0x00 | VERSION | R | `0x4E4E5545` ("NNUE", `NNUEHW_MAGIC`) |
| 0x04 | CONTROL | RW | bit0 START, bit1 RESET, bit2 IRQ_EN |
| 0x08 | STATUS | R | bit0 READY, bit1 BUSY, bit2 FAULT |
| 0x0C | DESC_HEAD | RW | HPS 생산자 인덱스 (doorbell) |
| 0x10 | DESC_TAIL | R | FPGA 소비 인덱스 |
| 0x14 | RESULT_HEAD | R | FPGA 생산 인덱스 |
| 0x18 | RESULT_TAIL | RW | HPS 소비 인덱스 |
| 0x1C | DONE | R | 완료 누계 (단조 증가) |
| 0x20 | IRQ_STATUS | R | bit0 RESULT_AVAIL, bit1 FAULT |
| 0x24 | IRQ_ACK | W | 해당 bit 쓰면 클리어 |

- **START 는 open 시점이 아닌 첫 submit 에 발행** (`DevMemBackend::submit`): 초기 open 에서
  미매핑 CSR 접근으로 인한 세그폴트/UTC hang 을 회피.
- v1 스펙의 CMD_BASE/CMD_LENGTH/NETCFG 등 DDR 링 레지스터는 없음 — 링은 항상 창 내 고정 영역.

---

## 5. Descriptor (64B 고정, `struct nnuehw_desc`)

| 필드 | 타입 | 설명 |
|---|---|---|
| magic | u32 | `NNUEHW_MAGIC` |
| mode | u32 | `ACCUMULATE(0) \| REFRESH(1)` — v1 FPGA 는 **REFRESH 만** 지원, ACCUMULATE → FAULT |
| bucket | u32 | 0..7 (LayerStacks) |
| side | u32 | stm: 0=WHITE, 1=BLACK (perspective) |
| n_add | u32 | add frame 의 유효 인덱스 수 (== cnt 합) |
| n_rem | u32 | rem frame 의 유효 인덱스 수 (REFRESH: 0) |
| add_frame | u32 | feature area frame idx (전체 목록) |
| rem_frame | u32 | 미사용 (v1, REFRESH) |
| seq | u32 | 응답 짝짓기 키 — result 에 그대로 echo |
| cnt_main0/1 | u32 | persp0/1 main feature 수 |
| cnt_thr0/1 | u32 | persp0/1 threat feature 수 (small: 0) |

### feature frame 레이아웃 (REFRESH)
```
[0 .. cnt_main0-1]                  persp0 main feature 인덱스
[cnt_main0 .. cnt_main0+cnt_main1-1]  persp1 main
[+cnt_thr0-1]                       persp0 threat (big 만)
[+cnt_thr1-1]                       persp1 threat (big 만)
n_add == cnt_main0+cnt_main1+cnt_thr0+cnt_thr1 <= 256
```
길이 검증: `sizeof(struct nnuehw_desc)==64` compile-time assert.

---

## 6. Result entry (16B 고정, `struct nnuehw_result`)

| 필드 | 타입 | 설명 |
|---|---|---|
| seq | u32 | 요청에서 echo |
| psqt | s32 | stm 관점 PSQT 합 (SF 와 동일 의미) |
| positional | s32 | FC 파이프라인 출력 (OutputScale 적용 전, stm 관점) |
| status | u32 | `OK(0) \| ERR_BUSY(1) \| ERR_FAULT(2)` |

- `status == 0` 일 때만 유효.

---

## 7. 가중치 로드 (`s_load`, 물리 `0xC0100000`)

풀 h2f 브리지의 `s_load` 레지스터 쌍 — CSR 창과 분리. UIO 로드 대신 **이 경로를 스트리밍** 사용.

| 레지스터 | 오프셋 | 설명 |
|---|---|---|
| LOAD_ADDR | 0x00 | 워드 주소 베이스. 상위 니블=`NNUEHW_LOAD_PLANE_*` 대상 선택 |
| LOAD_DATA | 0x04 | 32b 데이터 기록 후 주소+1 (자동 증가) |

평면 선택 상수 (워드 주소 `[31:28]`):
- `NNUEHW_LOAD_PLANE_FT   = 0x00000000`
- `NNUEHW_LOAD_PLANE_FC   = 0x10000000`
- `NNUEHW_LOAD_PLANE_PSQT = 0x20000000`

로드 순서 (SW `DevMemBackend::loadWeights(plane_base, src, n_words)`):
```
현재 LOAD_ADDR = plane_base
  for each 워드: LOAD_DATA = src[k]
STOP: 아무 값이나 LOAD_DATA 기록 후 즉시 로드 종료
```
- 내부 가중치 BRAM(`weight_bram`, L2 캐시 모델 M2) 용량은 FT 전체(210MB)를 담지 못함.
  **big net 대용량 FT/PSQT는 DDR 상수 로드**(FT_DDR_BASE `0x35000000` int16,
  PSQ_DDR_BASE `0x34000000` int32) — FPGA `ddr_stream` 이 f2h 마스터로 읽음.
- `s_load` 는 내부 BRAM(ft/fc/psq)에 대한 소형 로드/캐시 워밍 및 FC·PSQT 로드에 사용.

---

## 8. SW API (BACKEND — `nnue_batch.h`)

```cpp
class HWBackend {
    virtual bool open();                        // /dev/mem 두 개 매핑 (lw 창 + s_load)
    virtual void close();
    virtual bool submit(const EvalRequest&, uint32_t seq);   // 첫 호출 시 START 발행
    virtual bool pollResult(uint32_t seq, EvalResult&, int timeout_ms);
    virtual bool reset();
    virtual uint32_t doneCount();
    virtual uint32_t batchHint();
};

class DevMemBackend : public HWBackend {
    volatile uint32_t* window() const;          // lw 창 0xFF200000 (0x14000B)
    bool loadWeights(uint32_t plane_base, const void* src, uint32_t n_words);
};

class BatchScheduler {                          // enqueue/waitResult, 배치 Hint 만큼 submit
    uint32_t enqueue(const EvalRequest&);
    bool     waitResult(uint32_t seq, EvalResult&, int timeout_ms);
};
```

- `EvalRequest` 필드는 `nnuehw_desc` (mode/bucket/side/cnt_*/added/removed) 와 1:1.
- `MockBackend` = 호스트 유닛 테스트용 스칼라 러너. `UIOBackend` 는 퇴역(커널 UIO 없음).
- `nnuehw.h` 의 ioctl 인터페이스는 커널 드라이버 없이 사용되지 않음 — ABI 상호운용 보존용.

---

## 9. 요청/결과 흐름 (REFRESH 배칭)

```
1. evaluate_hw(): bucket/side/feature 인덱스 수집 → EvalRequest (REFRESH, n_rem=0)
2. feature frame 에 인덱스 기록 (persp0|persp1|thr0|thr1 순)
3. batch.enqueue(): descriptor[head&63] 기록 + seq 발급
4. 필요 시 batch.waitResult(): DESC_HEAD++(doorbell) → DONE/RESULT_HEAD 폴링(1ms)
5. result ring 에서 seq 매칭 entry 수거 → RESULT_TAIL 갱신
```
- 시퀀스 순서 유지: 링 FIFO 순서, 결과도 동일 순서 기록.
- 결과 즉시 필요(PV) 시 폴링 대기, 그 외 지연 허용.

---

## 10. 상태머신 요약

```
IDLE
 ├─ START=1 & DESC_HEAD!=DESC_TAIL → FETCH (descriptor pop)
 ├─ REFRESH: add frame 전체 → 어큐뮬레이터 재계산
 ├─ quantize transform → fc_0 → sqr/clip → fc_1 → clip → fc_2 → fwdOut 보정
 ├─ result 기록, RESULT_HEAD++, DONE++, IRQ_STATUS.RESULT_AVAIL
 └─ IDLE
FAULT: ACCUMULATE 요청 / weight 미설정 / 링 불일치 → STATUS.FAULT=1
```

---

## 11. 검증 게이트

- **G2 1차** (`devmem_smoke`): VERSION==MAGIC, CONTROL rw 왕복, s_load 3평면 기록, `--full` 창 sweep. ✅
- **G2 2차** (보드 수령 후): DevMemBackend submit→result 왕복, s_load 로드 무결성, 스칼라 참조와 bit-exact 비교.
- **G3**: UCI 스모크 (stockfish `nnue` path) + 성능 측정 (`bench`).