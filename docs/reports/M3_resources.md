# M3 자원·ABI 보고서

수행일: 2026-11-05. **상태: 일부 완료.** ABI와 자원 측정은 끝났지만, 실제 F2SDRAM 대역폭은 보드가 없어 측정하지 못했다.

> 2026-11-06 추가: F2SDRAM 대역폭·지연과 CSR 왕복을 보드에서 측정했다. 결과는 [board_f2sdram_csr.md](board_f2sdram_csr.md). 아래 본문은 2026-11-05 작성 그대로다.
>
> 2026-11-06 추가(성능 개선 뒤): CSR 표에는 20~22번(성능 카운터, `BUS`)과 FC cache 무효화를 반영했다. 그 밖의 바뀐 점은 다음과 같다. 자세한 것은 [성능 개선 제안](perf_proposal.md)에 있다.
> - `BUS_W = 128` 설정에서는 descriptor가 16-byte 정렬이고, `encode_descriptor`가 짝수 워드로 채운다. 형식(ABI 2)은 같다.
> - 보드 설계 자원: 4단계 128-bit 이미지 기준 ALM 10,200, M10K 240, DSP 43, 100 MHz setup +0.404 ns.
> - 아래 "위험과 미확정 사항"의 앞 세 항목은 해소됐다. ARM 측정이 있고(1.92배), 행 읽기는 read queue로 겹치며, 64·128-bit 포트를 보드에서 확인했다.

## 메모리 이미지

`tools/gen_spec.py`가 생성한다. 크기는 115,130,368 bytes이고 SHA-256은 `ce1d714bf7281ce4c15277beda6dbde502cabd593779f2cd06160a093396d229`다. 수치의 원본은 `hw/rtl/generated/nnue_spec_pkg.sv`다.

| 구역 | 오프셋 | 행 크기 | 내용 |
|---|---|---:|---|
| `ft_bias` | 0x00000000 | 2,048 | i16 × 1024 |
| `psq_weights` | 0x00001000 | 2,048 | 22,528행, i16 × 1024 |
| `psq_psqt` | 0x02C01000 | 32 | 22,528행, i32 × 8 |
| `active_weights` | 0x02CB1000 | 1,024 | 64,368행, i8 × 1024 (threat 59,808 + pawn-pair 4,560) |
| `active_psqt` | 0x06B8D000 | 32 | 64,368행, i32 × 8 |
| `stacks` | 0x06D84000 | 36,864 | layer stack 8개 |

layer stack은 FC 편향 264 bytes, FC0 열 1,024개(열당 32 bytes), FC1 열 64개(열당 32 bytes), FC2 128 bytes 순서다. FC 가중치를 입력 열 단위로 전치해, 입력이 0이면 읽기가 발생하지 않는다. 이 순서는 CPU SIMD 순서와 무관하다.

## Descriptor (ABI 2)

64-bit little-endian 워드, 8-byte 정렬.

| 워드 | 비트 | 내용 |
|---|---|---|
| 0 | [31:0] / [47:32] / [63:48] | magic `0x4E4E5546` / ABI 버전 / 예약(0) |
| 1 | [31:0] / [63:32] | network hash / net ID (SHA-256 앞 32비트) |
| 2 | [31:0] / [32] / [39:33] / [42:40] / [47:43] / [63:48] | sequence / 차례(0 백, 1 흑) / 예약 / bucket / 예약 / context ID |
| 3 | [7:0] / [15:8] / [23:16] / [25:24] / [27:26] / [63:28] | 목적지 슬롯 / 원본 슬롯(백) / 원본 슬롯(흑) / 연산(백) / 연산(흑) / 예약 |
| 4, 5 | 16비트씩 | 백, 흑의 PSQ 추가, PSQ 제거, active 추가, active 제거 개수 |
| 6~ | u16 × 4 | 백의 네 목록, 흑의 네 목록을 빈틈없이 이어 붙임 |

연산은 0 재사용, 1 refresh, 2 증분이다. 슬롯은 32개, 목록 제한은 PSQ 32개, active 256개다. refresh에는 제거 목록을, 재사용에는 어떤 목록도 줄 수 없다. 특징 생성은 HPS가 맡고 공식 코드와 같은 인덱스를 사용한다.

## CSR (32-bit 워드 오프셋)

| 오프셋 | 이름 | 내용 |
|---:|---|---|
| 0~3 | ID, ABI, HASH, NET | 읽기 전용 식별자 (`NNUE`) |
| 4 | CONTROL | bit0 시작, bit1 소프트 리셋, bit2 IRQ 허용, bit3 done·error 해제, bit4 모든 슬롯과 FC cache 무효화 |
| 5 | STATUS | bit0 busy, bit1 done, bit2 error, [15:8] 오류 코드 |
| 6, 7 | DESC, BASE | descriptor 주소(8-byte 정렬), 이미지 주소(4-KiB 정렬). BASE 쓰기는 모든 슬롯과 FC cache를 무효화. 가중치를 바꿀 때는 BASE를 다시 쓴다 |
| 8, 18 | SEQ, CTX | descriptor 값 반환 |
| 9, 10 | OUT_PSQT, OUT_POS | 최종 pair, `Network::evaluate()` 경계 |
| 11, 12 | RAW_PSQT, RAW_POS | `OutputScale` 나눗셈 이전 값 |
| 13~15 | CYCLES, WAITS, WORDS | FPGA 전용 cycle, 메모리 대기, 읽은 워드 수 |
| 16, 17 | TSEL, TDATA | tensor 디버그 포트. idle 상태에서만 유효하며, 누산기는 마지막 목적지 슬롯을 읽음 |
| 19 | SLOTS | 슬롯 수 |
| 20, 21 | PSEL, PDATA | 단계별 cycle·요청 카운터 선택과 읽기(`nnue_golden.h`의 `PERF_NAMES`) |
| 22 | BUS | 메모리 데이터 폭(64 또는 128). 128이면 DESC는 16-byte 정렬, WORDS는 16 B beat 수이고, 호스트가 `fpgaportrst`에 0x133을 써야 한다 |

오류 코드는 1 magic, 2 ABI, 3 hash, 4 net ID, 5 범위, 6 예약 비트, 7 timeout, 8 정렬, 9 슬롯이다. 잘못된 net이나 ABI는 가중치를 읽기 전에 거부한다. 중단 후 남은 읽기 응답은 폐기하며, 다음 실행은 이 응답이 모두 도착할 때까지 시작하지 않는다.

## FPGA 자원 (실측)

Quartus Prime Lite 25.1std, `5CSEMA5F31C6`, `nnue_core` 단독 fit. clk 외 포트는 virtual pin이다. **Platform Designer, HPS, CDC, 실제 핀이 포함되지 않았으므로 보드 timing closure가 아니다.**

| 자원 | 사용 | 전체 | 비율 |
|---|---:|---:|---:|
| ALM | 7,903 | 32,070 | 25% |
| 레지스터 | 6,944 | | |
| M10K | 136 | 397 | 34% |
| DSP | 27 | 87 | 31% |

100 MHz 제약에서 Fmax는 107.28 MHz(Slow 85C)와 111.58 MHz(Slow 0C)다. 전 corner 최악 setup slack은 +0.679 ns, hold slack은 +0.131 ns다. M10K 증가분은 슬롯 32개 때문이다. 이 표는 FC cache 전의 독립 compile 값이다. 보드 설계에 FC cache를 넣은 뒤의 값(M10K 207, DSP 43)은 [성능 개선 제안](perf_proposal.md)에 있다.

## 메모리 traffic (계산)

| 항목 | 값 |
|---|---|
| 평가당 평균 읽기, 전체 refresh, M4 corpus | 6,100 워드 (약 48.8 KB) |
| 평가당 평균 읽기, 증분 경로, 탐색 trace | 9,983 워드 (약 79.9 KB) |
| 평가당 평균 읽기, 증분 경로, 무작위 수순 | 2,917 워드 (약 23.3 KB) |
| 슬롯이 모두 찬 경우의 특징 행 읽기 | 84,224 워드 (약 674 KB) |
| 전체 refresh, 이상적 메모리(지연 1 cycle)에서의 cycle | 최소 3,890, 중앙값 5,399, p95 25,760, p99 38,039, 최대 44,010 |
| 위 값의 100 MHz 환산 | 중앙값 54.0 µs, p99 380 µs, 최대 440 µs |

이 시간은 실제 지연이 없는 메모리를 가정한 **FPGA 계산 전용 추정치**이며 측정이 아니다. 실제 DDR 지연, 경합, 통신, 동기화, 결과 회수가 빠져 있어 BENCHMARK의 주 지표로 사용할 수 없다. corpus가 종반에 치우쳐 평균도 낮게 나온다.

## 위험과 미확정 사항

- **속도 향상은 아직 근거가 없다.** ARM 측정값이 없다. 증분 경로는 M5에서 구현했지만 Finny table에 해당하는 cache가 없어, 탐색에서 refresh 비중이 높다([M5 보고서](M5_incremental.md)).
- **메모리가 병목이 될 가능성이 크다.** 행 하나를 끝까지 받은 뒤에야 다음 행을 요청하므로 메모리 지연이 행마다 더해진다. 필요하면 prefetch로 개선한다.
- F2SDRAM 포트의 64-bit 폭과 16워드 burst는 설계 가정이다. 실제 HPS 설정으로 확인해야 한다.
- 대역폭 측정 IP는 미구현이다. (2026-11-06: `hw/rtl/board/mem_probe.sv`로 구현하고 보드에서 측정했다.)
- 가중치 이미지는 HPS DDR3에 두는 안을 전제로 했다. FPGA-side DDR3와의 최종 선택은 측정 뒤에 확정한다.
