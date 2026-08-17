# nnuehw.ko — DE1-SoC 대상 커널 모듈 빌드
# 사용법:
#   make KDIR=/path/to/de1soc-kernel   # 보드 커널 소스 트리 (빌드된 상태)
#   KDIR 는 DE1-SoC BSP 커널 (config: UIO=y, UIO_PDRV_GENIRQ=y 또는 UIO=y + of) 필요
#
# 호스트(macOS) 에서는 빌드 불가 — Lima VM 또는 보드의 커널 트리에서 실행.
ifneq ($(KERNELRELEASE),)
obj-m := nnuehw.o
ccflags-y := -I$(src)
else
KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

dtbs:
	@echo "device tree overlay (수동 적용):"
	@echo "  &hps_0_bridges { nnue_hw: nnue@0xC000 {"
	@echo "      compatible = \"nnue,nnue-hw-1.0\";"
	@echo "      reg = <0x0000C000 0x00014000>;"
	@echo "      interrupt-parent = <&intc>;"
	@echo "      interrupts = <0 42 4>;   /* GIC SPI 42, high-level — RTL 배선에 맞게 조정 */"
	@echo "  }; };"
endif