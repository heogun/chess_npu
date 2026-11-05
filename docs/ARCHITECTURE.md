# SF19 / DE1-SoC 설계 계약

## 비트 일치 경계

주 검증 경계는 공식 `src/nnue/network.cpp`의 `Network::evaluate()`가 반환하는 `NetworkOutput = std::tuple<Value, Value>`다. 반환 순서는 `psqt / OutputScale`, `positional / OutputScale`이다. 같은 네트워크·입력 상태·관점에서 두 정수 모두 **오차 0**이어야 한다. 내부 FT·PSQT·FC 중간값도 비교하여 최종 나눗셈으로 가려지는 오차를 잡는다.

최종 `Eval::evaluate()` 보정과 탐색은 HPS에서 유지한다. 별도 통합 게이트에서 동일 optimism·상태의 최종 정적 평가도 비교한다. 시간 제한 탐색의 bestmove는 처리 속도에 따라 달라질 수 있으므로 NNUE 비트 일치 판정 기준으로 삼지 않는다.

공식 코드를 호출하는 C++ harness가 golden oracle이다. 손으로 다시 쓴 평가기는 보조 진단으로만 사용한다. signedness, 곱셈 중간 비트폭, SIMD 포화, truncation, 산술 우측 시프트, C++의 0 방향 정수 나눗셈, concat·skip 경로를 연산별 명세로 고정한다. 임의 재양자화·가중치 축소·가지치기를 하지 않는다.

## 공식 checkout으로 확인한 구조

- SFNNv16, 단일 네트워크. SF18 big/small 분기는 없다.
- 특징군: `HalfKAv2_hm`, `FullThreats`, `PP_3Wide`.
- `L1=1024`, `L2=32`, `L3=32`, PSQT buckets와 layer stacks는 각각 8.
- FC0 1024→32, FC1 64→32, FC2 128→1. squared/clipped 활성화를 concat하며 FC0 마지막 두 출력의 차이를 skip으로 더한다.
- `OutputScale=16`, `WeightScaleBits=6`, `HiddenOneVal=128`.
- 기본 네트워크 `nn-1a298aa575a0.nnue`, 파일 버전 `0x6A448AFA`.

근거: `src/evaluate.h`, `src/nnue/{nnue_architecture.h,nnue_common.h,network.h,network.cpp}`, `src/nnue/features/`. 이 수치를 여러 RTL에 수동 복사하지 않는다. M1에서 소스·실제 net에서 사양을 추출하여 빌드 입력으로 만든다.

## 모듈 경계

| 계층 | 책임 |
|---|---|
| 버전 어댑터 | sf19 특징 인덱스·refresh 조건·network 파싱·공식 평가 호출 |
| 사양 생성기·패커 | 차원·타입·scale·hash·bucket·DDR stride를 JSON, SV package, C++ header로 함께 생성. CPU SIMD 순서와 FPGA 순서를 구분 |
| 연산 RTL | accumulator·quantizer·MAC·활성화·skip/scaling. 새 연산은 명시적으로 확장 |
| 보드 계층 | Cyclone V memory master·CSR·IRQ·reset/CDC·Platform Designer |
| Linux 계층 | DMA buffer 소유권·cache sync·timeout·오류. CPU 가상주소를 FPGA 주소로 사용하지 않음 |
| 엔진 어댑터 | 작은 patch series, CPU/HW/비교 모드, thread별 context ID·accumulator 상태 |

HPS는 규칙·특징 생성·탐색·Linux를, FPGA는 전체 NNUE 연산을 담당한다. 처음에는 전체 refresh로 정확성을 확보하고 이후 증분 업데이트·cache를 추가한다. 특징 생성은 초기에는 HPS에서 수행해 버전 변경 범위를 좁힌다.

대형 FT는 HPS DDR3에 두고 F2SDRAM으로 읽는 설계를 우선 검토한다. M10K는 FC·타일·누산기·FIFO에 배분한다. FPGA-side DDR3는 대안이며 실제 패킹 크기·측정 대역폭으로 배치를 확정한다. 50 MHz 입력에서 PLL을 사용하며 내부 100 MHz는 초기 목표이지 검증 결과가 아니다. 핀·HPS DDR 설정은 보드 revision에 맞는 Terasic reference로 검증한다.

CSR/descriptor/result에는 ABI version, architecture hash, network 식별자, context/sequence ID, status를 포함한다. 엔진·가중치·bitstream 식별자가 맞지 않으면 HW 실행을 거부한다. fallback은 명시적으로 보고하고 HW 정확성 시험에서는 금지한다. 미래 구조를 파라미터 변경만으로 모두 지원한다고 가정하지 않는다.
