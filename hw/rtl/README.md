SF19 연산 RTL·protocol·memory·top·testbench. 기존 SF18 RTL은 archive의 복구본에서만 검토한다.

상태: 전체 refresh(M4)와 증분·슬롯(M5) 코어를 Verilator로 검증했고, 보드 top에 넣어 실제 DE1-SoC에서 refresh corpus 100,000개와 탐색 trace 94,770개를 비트 일치로 통과했다(2026-11-06). 다중 context·중단·실행 중 reset 시험은 시뮬레이션에서만 통과했다.

| 파일 | 내용 |
|---|---|
| `generated/nnue_spec_pkg.sv` | `tools/gen_spec.py` 생성물. 직접 수정하지 않는다 |
| `nnue_math_pkg.sv` | clamp, 활성화, 0 방향 나눗셈 등 정수 연산 |
| `nnue_core.sv` | 메모리 master, CSR, descriptor, 누산기 슬롯, refresh·증분 파이프라인, FC cache, read queue |
| `sdp_ram.sv` | M10K로 추론되는 simple dual-port RAM |
| `board/board_top.sv` | DE1-SoC top. `USE_NNUE`(0이면 `mem_probe`, 1이면 `nnue_core`), `SDRAM_W`(64 또는 128) |
| `board/mem_probe.sv` | F2SDRAM 대역폭·지연 측정 master. `DATA_W` 64 또는 128 |
| `tb/tb_core.cpp` | 코어 testbench. 무작위 stall 메모리 모델, golden tensor 비교, 요청 계획 정책(`--policy`, `--candidates`) |
| `tb/tb_math.cpp`, `tb/nnue_math_unit.sv` | 산술 단위시험 |
| `tb/tb_mem_probe.cpp` | `mem_probe` testbench |

`nnue_core` 파라미터:

| 파라미터 | 기본값 | 내용 |
|---|---|---|
| `FC_CACHE` | 1 | 최근 bucket 2개의 FC 층을 M10K에 둔다 |
| `READ_QUEUE` | 1 | 누산기 단계의 행·PSQT 읽기를 queue로 겹친다 |
| `BUS_W` | 64 | 메모리 폭. 128은 `FC_CACHE = 1`이 필요하다. 보드의 현재 이미지는 128이다 |
| `WATCHDOG_CYCLES` | 2^20 | 메모리 진행이 없을 때 `ERR_TIMEOUT`까지의 cycle |

기능을 끈 설정(`FC_CACHE = 0`, `READ_QUEUE = 0`, `BUS_W = 64`)은 각 기능을 넣기 전과 시뮬레이션 사이클이 같다. `tools/build-sim.sh`가 기본 설정과 128-bit 설정(`core_b128`)을 함께 빌드한다.

레지스터와 descriptor 형식은 [M3 보고서](../../docs/reports/M3_resources.md)에 있다. Quartus Standard는 반복문 안에서 곱셈과 cast로 계산한 index를 잘못 elaborate할 수 있다. compile 뒤 map 경고 10030·10027을 확인한다([성능 개선 제안](../../docs/reports/perf_proposal.md)의 4단계 절).
