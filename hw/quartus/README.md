DE1-SoC 전용 QPF/QSF/SDC, Platform Designer 원본·IP 정의. 생성물은 build 아래 둔다. 보드 revision과 실제 Quartus 버전 확인 후 구성한다.

상태: 계획 단계. SF19 구현·검증 미완료.

`fit_core.tcl`은 코어 단독의 자원과 Fmax 측정용이다. 포트가 virtual pin이라 프로그램할 수 없으며 DE1-SoC top이 아니다. 보드 프로젝트(M6)의 가속기 top은 미구현이다. F2SDRAM·CSR 측정용 보드 구성은 [`board/`](board/README.md)에 있고, 보드 측정까지 마쳤다([결과](../../docs/reports/board_f2sdram_csr.md)).
