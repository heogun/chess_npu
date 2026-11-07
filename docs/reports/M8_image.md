# M8 이미지·배포 보고서

수행일: 2026-11-07. **이 결과는 실제 DE1-SoC에서 잰 것이다.** 이미지는 새로 만든 WSL 배포판에서 고정된 입력만으로 만들었다. 그 이미지를 카드에 쓰고, 부팅해 회귀를 돌렸다.

## 결과: 게이트 통과

| 게이트 항목 | 결과 |
|---|---|
| 깨끗한 WSL에서 이미지 재생성 | 새 배포판 `chessnpu-clean`에서 `tools/build-release.sh` 한 번으로 27분 20초. 배포판은 Ubuntu 26.04.1 공식 `.wsl` 이미지를 SHA-256 확인 뒤 import한 것이다. 프로젝트 commit `47509fc`이고 작업 트리는 깨끗했다 |
| SD 기록 | `de1soc.img` 4,312,793,088 bytes, SHA-256 `22ab8cb6…e380fe`. 기록에 462 s, 다시 읽은 hash가 같다 |
| SD cold boot 반복 | 서로 다른 부팅 4회. 전원을 다시 넣은 부팅이 2회, reboot가 2회다. FPGA 이미지가 있는 3회는 자체 검사 PASS, 없는 1회는 FAIL로 정확히 보고했다(아래 복구 절차) |
| 온보드 회귀 (`regress.sh`) | 정확성 9개 항목 모두 PASS. 시간 측정 10회 동안에도 mismatch·error·fallback 0 |
| M3 기준과 비교 | 아래 "성능"의 마지막 표. 평가당 DDR 읽기는 M3 추정(탐색 trace 79.9 KB)의 38 %인 30.0 KB다 |

판정: **통과.** 온도·전력 측정과 두 번째 빌드로 재현성을 확인하는 일은 2026-11-07 범위에서 뺐다(아래 "하지 않은 것").

로그: [board_m8](logs/board_m8/).

- `boot1.txt`, `boot2.txt`, `recovery_cpu_only.txt`, `boot3_restored.txt`: 부팅 기록.
- `regress-561898df-0/`: 회귀 결과 전부.
- `release/`: manifest, `SHA256SUMS`, FPGA 출처, package 목록, Debian 소스 목록.
- `session.txt`: 회귀 중 serial 기록.

## 이미지

| 항목 | 값 |
|---|---|
| 이미지 ID | `47509fc3e57c` (프로젝트 commit 앞 12자리, dirty 아님) |
| Boot chain | U-Boot v2026.07 `ece349ad` (SPL, `FPGAPORTRST` 0x133 patch), Linux v6.12.115 `03bae623`, Debian trixie armhf (snapshot `20261101T000000Z`, mmdebstrap) |
| 파티션 | raw `a2` 1 MiB에서 16 MiB (SPL과 U-Boot), ext4 root 17 MiB에서 4 GiB. 압축 이미지 `de1soc.img.xz`는 1.05 GB |
| 엔진 | `stockfish` (공식 sf_19, armv7-neon, net 내장) `c1658321…`. `stockfish-fpga` (같은 소스와 adapter, net 내장) `6c1b802a…` |
| Net | `nn-1a298aa575a0.nnue`, SHA-256 `1a298aa5…2dfc2`, 98,511,183 bytes |
| FPGA | `board.rbf` `7c581145…07d2`, Quartus 25.1std.0 Lite, 5CSEMA5F31C6 |
| Toolchain | g++ / arm-linux-gnueabihf-g++ 15.2.0-16ubuntu1, mmdebstrap 1.5.7, mke2fs 1.47.2 |
| 고정한 것 | `SOURCE_DATE_EPOCH` = commit 시각 1794048325, Kbuild 시각·사용자·호스트, ext4 UUID·hash seed·시각, MBR label-id |

- 회귀 corpus는 빌드 때 새로 만든다. 다시 만든 `stim.bin`(100,000개)과 `search.ev`, `bench.ops`, 가중치 이미지는 이전 환경의 파일과 byte 단위로 같았다.
- FPGA 이미지는 Windows Quartus에서 qsys부터 다시 빌드했다(54분). 결과는 카드에 있던 `.rbf`와 byte 단위로 같았다.
- `board.rbf.json`의 `project_commit`은 `55f2ac5`다. rbf를 만든 시점의 commit이고, 그 뒤 `47509fc`까지 `hw/` 트리는 바뀌지 않았다.
- U-Boot 배너는 `2026.07-dirty`로 나온다. 프로젝트 patch를 U-Boot 작업 트리에 적용했기 때문이다(`setlocalversion`). 빌드 시각은 고정한 값(10:45:25 UTC)이다.

## 부팅과 자체 검사

`chess-npu-selftest.service`가 부팅마다 한 번 돈다. 검사 항목은 FPGA 적재, 파일 hash, refresh 2,000개와 증분 3,000개(10번째마다 중간 tensor 비교), 엔진 비교 모드 depth 7, 공식 엔진과의 노드 수 비교다.

| 부팅 | 방법 | boot ID | 결과 |
|---|---|---|---|
| 1 | 카드 기록 뒤 첫 전원 | `561898df` | PASS, 65.7 s. 이 부팅에서 전체 회귀를 돌렸다 |
| 2 | `poweroff` 뒤 전원 다시 넣음 | `0c143270` | PASS, 64.6 s |
| 3 | `board.rbf` 이름을 바꾸고 reboot | `07e0dfc8` | **FAIL** `fpga_loaded`. 가속기 검사는 건너뛰고 그렇다고 기록했다 (의도한 결과) |
| 4 | 이름을 되돌리고 reboot | `3b7eaceb` | PASS, 63.8 s |

- PASS 부팅 3회는 모두 같은 결과를 냈다. 비교 모드 평가 36,992개, mismatch 0, 노드 108,256(depth 7, 공식 엔진과 같음). refresh·증분 mismatch·error·fallback도 모두 0이다.
- 이미지 ID, U-Boot·커널 빌드 문자열, `mem=768M`이 모든 FPGA 부팅에서 같았다.
- 부팅 2에서 `systemctl is-system-running`은 `running`, failed unit은 0개였다.
- UART 자동 로그인(root)은 정상이었다. root 파일시스템은 3.9 GB이고 1.5 GB가 남는다.
- Ethernet은 케이블이 없어 link DOWN이다. 네트워크 동작은 확인하지 않았다.
  - 뒤에 찾은 결함: 이 이미지의 DHCP 설정은 `Name=eth*`이지만 인터페이스 이름은 `end0`이라, 케이블이 있어도 주소를 받지 못한다. `linux/rootfs-customize.sh`에서 `Name=end* eth*`로 고쳤고 다음 이미지에 들어간다(보드 확인 전).
- 보드 시계는 맞추지 않았다(로그 시각 2026-04-13). 시각을 쓰는 검사는 없다.

### 복구 절차

- **CPU 전용 부팅:** 확인했다(부팅 3).
  - U-Boot는 `Failed to load '/boot/fpga/board.rbf'`, `No FPGA image, CPU-only boot`를 출력하고 `mem=768M` 없이 부팅했다. 메모리는 1,000 MB 전부가 보였다.
  - 자체 검사는 CPU 경로로 대신하지 않고 FAIL로 보고했다.
  - 공식 `stockfish bench 16 1 7`은 108,256 노드, 17,010 NPS로 정상이었다.
  - 이름을 되돌리자 다음 부팅(4)이 다시 PASS였다.
- **백업 이미지로 되돌리기:** 실제로 해 보지는 않았다.
  - M8 전 카드의 백업(`card_before_m8.img`, 3.2 GB, SHA-256 `854262af…7fbf58b`)은 두 번 읽어 같음을 확인해 두었다.
  - 이 백업을 다시 쓰고 부팅하는 일은 하지 않았다.

## 성능 (정확성 통과 뒤)

`regress.sh`의 시간 단계다. warm-up 1회 뒤 10회를 돌았고, 각 회차에서 ARM 단독과 ARM+FPGA를 차례로 실행했다. 두 경로를 동시에 돌리지 않았다. 아래 값은 10회의 평균이고, 회차 간 차이는 ±0.3 % 안이다.

### NNUE 평가 (탐색 trace 94,770개, bench 51개 위치에서 뽑은 window)

| 모드 | 불일치 / 오류 / fallback | median / p95 / p99 | 평균 | eval/s | ARM 단독 대비 |
|---|---|---|---:|---:|---:|
| ARM 단독 (`arm_replay`, NEON) | 기준 (pair·기록값 951,268개 mismatch 0) | 110.84 / 221.12 / 334.76 µs | 124.54 µs | 8,030 | 1.0 |
| ARM+FPGA, 호스트 관측 | 0 / 0 / 0 (382,363값 비교) | 32.14 / 66.40 / 98.16 µs | 35.84 µs | 27,902 | 3.47 |
| ARM+FPGA, ARM 쪽 인코딩 포함 | 같음 | (인코딩 median 5.01 µs) | 40.84 µs | **24,486** | **3.05** |
| FPGA 계산만 (참고) | | 27.24 / 60.72 / 92.09 µs | 31.06 µs | | |

- 호스트 관측 시간에는 서술자 쓰기, 시작, polling, 결과 읽기가 들어 있다.
- ARM+FPGA 쪽은 특징 목록이 trace에 미리 들어 있다. 그래서 이 가속비는 NNUE 평가만 비교한 값이다.
- M7의 같은 측정은 35.86 µs, 40.82 µs, 3.05배였다. 새 빌드와 새 카드에서도 같은 값이 나왔다.

### 엔진 전체 (공식 `bench`, Hash 16 MB, Threads 1, depth 13, 51개 위치)

| 모드 | 노드 | 시간 (중앙값) | NPS | ARM 단독 대비 |
|---|---:|---:|---:|---:|
| ARM 단독 (공식 `stockfish`) | 2,497,913 | 146.47 s | 17,056 ± 20 | 1.0 |
| ARM+FPGA (`stockfish-fpga`, `SF_NNUE_MODE=hw`, `SF_NNUE_PLANNER=hw`) | 2,497,913 | 75.13 s | 33,258 ± 35 | **1.95** |

- 노드 수는 11회 모두 공식 값과 같았고, error·fallback은 0이었다.
- 비교 모드 bench를 따로 한 번 돌려 평가 951,268개의 pair가 모두 같음을 확인했다.
- M7은 17,036 / 33,299 NPS, 1.95배였다.
- ARM 단독은 M7과 달리 `stockfish-fpga`의 cpu 모드가 아니라 수정 없는 공식 이진 파일이다. 둘은 1 % 안에서 같다(17,056 대 17,036).

### M3 기준과 비교

| 항목 | M3 (2026-11-05, 계산·추정) | M8 (보드 실측) |
|---|---|---|
| 평가당 DDR 읽기, 탐색 trace | 9,983 워드 × 8 B = 79.9 KB (64-bit, cache 없음 추정) | 1,871.9 beat × 16 B = **30.0 KB** (128-bit 포트, FC cache와 가까운 slot 계획) |
| 평가 중 DDR 읽기 속도 | (해당 없음) | 30.0 KB / 31.06 µs ≈ 0.96 GB/s. 포트 상한 1.6 GB/s, 측정한 순차 최대 1,567 MB/s |
| 계산 시간 | 전체 refresh 중앙값 54.0 µs (지연 없는 메모리 가정) | FPGA 계산 중앙값 27.24 µs (실제 DDR, 탐색 trace) |
| ARM 단독 대비 | 근거 없음 ("ARM 측정값이 없다") | NNUE 3.05배, 엔진 1.95배 |

- 코어 시간 중 가장 큰 항목은 여전히 행 읽기 대기다. 성능 카운터 기준 `row_wait`가 코어 cycle의 61 %다(294 M cycle 중 180 M).

### 자원

| 항목 | 사용 | 비율 |
|---|---:|---:|
| ALM | 15,223 / 32,070 | 47 % |
| 레지스터 | 12,997 | |
| M10K | 291 / 397 | 73 % |
| Block memory bits | 2,031,104 / 4,065,280 | 50 % |
| DSP | 68 / 87 | 78 % |
| 최악 slack (100 MHz 코어) | setup +0.573 ns, hold +0.144 ns | |
| 최악 slack (HPS SDRAM AFI) | setup +1.727 ns, hold +0.077 ns | |

- Quartus map 경고 10030/10027은 알려진 `mac_value` 한 줄뿐이다(구동하지 않는 net, 0으로 초기화).
- HPS 메모리: FPGA 부팅에서 Linux가 768 MiB를 쓴다. 나머지 256 MiB는 가중치 이미지(115,130,368 bytes)와 서술자에 쓴다.

### 온도·전력: 범위에서 뺌

- 보드 Linux에는 hwmon과 thermal 장치가 없다.
- Quartus의 `altera_temp_sense` IP는 Arria V, Arria V GZ, Stratix IV, Stratix V, Arria 10만 지원한다. Cyclone V는 목록에 없다.
- 외부 전력계도 없다.
- Quartus Power Analyzer 추정치는 측정이 아니라서 만들지 않았다.
- 회귀 중 반복 간 변동은 ±0.3 % 안이었다. 시간이 지나면서 느려지는 경향은 보이지 않았다.

## 대응 소스와 license

`tools/make-source-bundle.sh <release> --debian`이 release 디렉터리 안에 `sources/`(765 MB)를 만들었다. 내려받기에 2시간 15분이 걸렸다. snapshot.debian.org가 503을 두 번 돌려주었지만, `curl --retry`가 다시 받아 빠진 파일은 없다. 스크립트는 `pipefail`이라 실패하면 멈춘다.

| 내용 | 크기 |
|---|---:|
| 프로젝트 `git archive` (`47509fc`) | 640 KB |
| Stockfish sf_19 | 284 KB |
| U-Boot v2026.07 | 44 MB |
| Linux v6.12.115 | 145 MB |
| License (Stockfish `Copying.txt`, U-Boot `Licenses/`, Linux `COPYING`, `LICENSES/preferred`, `exceptions`) | 292 KB |
| Debian 소스 패키지 115개(binary 178개의 원천), `.dsc`와 원본·diff 파일 257개 | 576 MB |

- Debian 파일 257개는 모두 각 `.dsc`의 `Checksums-Sha256`과 같았다.
- release의 `SHA256SUMS`(420개, build log 제외)를 다시 만들었고, `sha256sum -c`가 통과했다.
- 각 Debian package의 license는 이미지 안 `/usr/share/doc/<package>/copyright`에 있다.
- **프로젝트 자체에는 license 파일이 없다.** `stockfish-fpga`는 GPLv3인 Stockfish에 이 프로젝트의 adapter를 더한 것이다. 이를 배포하려면 adapter 코드의 license를 정해야 한다. 이는 프로젝트 소유자가 정할 일이고, 이 보고서에서 정하지 않았다.

## 하지 않은 것

- 온도·전력 측정: 측정 수단이 없어(위) 범위에서 뺐다(2026-11-07 결정).
- 같은 commit으로 두 번째 빌드를 해서 byte 단위로 같은지 확인: 범위에서 뺐다(2026-11-07 결정). 고정 장치는 넣었지만 재현성은 확인되지 않았다.
- 백업 이미지로 카드를 되돌리는 시험(위).
- Ethernet·SSH, 시각 동기화.
- 시간 제한 대국 강도(Elo).
- 다중 thread·다중 context, IRQ·kernel driver(M6·M7의 남은 일과 같다). 다중 thread·다중 context는 다음 개선 후보다.

## 바뀐 파일

- 이미지 안: `linux/rootfs-overlay/` (`selftest.sh`, `regress.sh`, `chess-npu-selftest.service`), `linux/rootfs-customize.sh`. adapter의 기본 가중치 경로는 `/usr/share/chess-npu/weights.bin`이다.
- 빌드: `tools/build-release.sh`, `tools/release_manifest.py`, `tools/make-source-bundle.sh`, `tools/build-rootfs.sh`, `tools/make-sd-image.sh`, `tools/build-boot.sh`(재현용 고정값).
- Windows: `tools/export-rbf.ps1`, `tools/read-sd.ps1`. `.gitattributes`로 script를 LF로 고정했다.
- 깨끗한 환경에서 드러난 문제로 고친 것:
  - script 실행 비트.
  - refresh corpus가 5,000개만 만들어지던 것(`--stim-every 1`).
  - 임의 MBR label-id.
  - mmdebstrap `sync-in` 대상 디렉터리.
  - Debian `.dsc` 파일 목록의 빈 줄 처리.
