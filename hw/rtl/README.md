SF19 연산 RTL·protocol·memory·top·testbench. 기존 SF18 RTL은 archive의 복구본에서만 검토한다.

상태: 전체 refresh(M4)와 증분·슬롯(M5) 코어를 Verilator로 검증했다. **보드 미검증이다.** DE1-SoC top(M6)은 미구현이다.

| 파일 | 내용 |
|---|---|
| `generated/nnue_spec_pkg.sv` | `tools/gen_spec.py` 생성물. 직접 수정하지 않는다 |
| `nnue_math_pkg.sv` | clamp, 활성화, 0 방향 나눗셈 등 정수 연산 |
| `nnue_core.sv` | 메모리 master, CSR, descriptor, 누산기 슬롯, refresh·증분 파이프라인 |
| `sdp_ram.sv` | M10K로 추론되는 simple dual-port RAM |
| `tb/` | Verilator testbench |

레지스터와 descriptor 형식은 [M3 보고서](../../docs/reports/M3_resources.md)에 있다.
