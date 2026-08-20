# fpga_top_soc Qsys 컴포넌트 정의
#
# M4-RTL 배칭 NPU(fpga_top)를 Avalon-MM 슬레이브 2개 + 인터럽트 소스로 노출한다.
#   - s_hps  : HPS 창 메모리 (lwhps2fpga 브리지 연결, byte 주소 18비트, 스팬 0x40000)
#   - s_load : 가중치 로드 레지스터 (hps2fpga 브리지 연결, byte 주소 8비트, 스팬 0x100)
#   - irq_out: FPGA-to-HPS 인터럽트 (f2h_irq0)
#
# RTL 파일은 hw/rtl/ 하위를 상대 경로로 참조한다 (이 파일 위치: hw/quartus/ip/fpga_top_soc/).

package require -exact qsys 14.0

set_module_property NAME fpga_top_soc
set_module_property VERSION 1.0
set_module_property INTERNAL false
set_module_property DISPLAY_NAME "NNUE Batch NPU (fpga_top_soc)"
set_module_property DESCRIPTION "NNUE batch accelerator Avalon-MM wrapper (M4-RTL)"
set_module_property GROUP "Chess NPU"
set_module_property EDITABLE false

# -----------------------------------------------------------------------------
# 파라미터 (보드 기본값은 small net; big net은 명시적으로 오버라이드)
# -----------------------------------------------------------------------------
add_parameter HD         INTEGER 128
set_parameter_property HD         DISPLAY_NAME "Hidden dimension (HD)"
set_parameter_property HD         ALLOWED_RANGES {128 1024}
set_parameter_property HD         AFFECTS_GENERATION true

add_parameter NF         INTEGER 22528
set_parameter_property NF         DISPLAY_NAME "Main feature dimension (NF)"
set_parameter_property NF         AFFECTS_GENERATION true

add_parameter TFF        INTEGER 0
set_parameter_property TFF        DISPLAY_NAME "Threat feature dimension (TFF, small=0)"
set_parameter_property TFF        AFFECTS_GENERATION true

add_parameter PSQI       INTEGER 22528
set_parameter_property PSQI       DISPLAY_NAME "Main PSQT input dimension (PSQI)"
set_parameter_property PSQI       AFFECTS_GENERATION true

add_parameter FT_ADDR_W  INTEGER 22
set_parameter_property FT_ADDR_W  DISPLAY_NAME "FT weight address width"
set_parameter_property FT_ADDR_W  AFFECTS_GENERATION true

add_parameter FC_ADDR_W  INTEGER 15
set_parameter_property FC_ADDR_W  DISPLAY_NAME "FC weight address width"
set_parameter_property FC_ADDR_W  AFFECTS_GENERATION true

add_parameter PSQ_ADDR_W INTEGER 18
set_parameter_property PSQ_ADDR_W DISPLAY_NAME "PSQT weight address width"
set_parameter_property PSQ_ADDR_W AFFECTS_GENERATION true

add_parameter FT_DDR_BASE INTEGER 0x35000000
set_parameter_property FT_DDR_BASE DISPLAY_NAME "FT weight DDR3 base byte address"
set_parameter_property FT_DDR_BASE AFFECTS_GENERATION true

add_parameter PSQ_DDR_BASE INTEGER 0x34000000
set_parameter_property PSQ_DDR_BASE DISPLAY_NAME "PSQT weight DDR3 base byte address"
set_parameter_property PSQ_DDR_BASE AFFECTS_GENERATION true

# -----------------------------------------------------------------------------
# HDL 파일 (hw/rtl 기준 상대 경로)
# -----------------------------------------------------------------------------
add_fileset quartus_synth QUARTUS_SYNTH "" ""
set_fileset_property quartus_synth TOP_LEVEL fpga_top_soc
add_fileset_file fpga_top_soc.sv    SYSTEM_VERILOG PATH rtl/fpga_top_soc.sv
add_fileset_file fpga_top.sv        SYSTEM_VERILOG PATH rtl/fpga_top.sv
add_fileset_file top_fte.sv         SYSTEM_VERILOG PATH rtl/top_fte.sv
add_fileset_file fte.sv             SYSTEM_VERILOG PATH rtl/fte.sv
add_fileset_file accumulator.sv     SYSTEM_VERILOG PATH rtl/accumulator.sv
add_fileset_file quantize.sv        SYSTEM_VERILOG PATH rtl/quantize.sv
add_fileset_file weight_stream.sv   SYSTEM_VERILOG PATH rtl/weight_stream.sv
add_fileset_file top_fc.sv          SYSTEM_VERILOG PATH rtl/top_fc.sv
add_fileset_file fc_pipe.sv         SYSTEM_VERILOG PATH rtl/fc_pipe.sv
add_fileset_file fc_bram.sv         SYSTEM_VERILOG PATH rtl/fc_bram.sv
add_fileset_file psq_stream.sv      SYSTEM_VERILOG PATH rtl/psq_stream.sv
add_fileset_file ddr_stream.sv      SYSTEM_VERILOG PATH rtl/ddr_stream.sv
add_fileset_file nnue_defs.sv       SYSTEM_VERILOG PATH rtl/nnue_defs.sv


# -----------------------------------------------------------------------------
# 인터페이스
# -----------------------------------------------------------------------------
# 클록
add_interface clk clock end
set_interface_property clk EXPORT_OF ""
set_interface_property clk ENABLED true
add_interface_port clk clk clk Input 1

# 리셋 (active-low)
add_interface reset_n reset end
set_interface_property reset_n associatedClock clk
set_interface_property reset_n synchronousEdges DEASSERT
set_interface_property reset_n ENABLED true
add_interface_port reset_n reset_n reset_n Input 1

# ---- 슬레이브 1: HPS 창 (lwhps2fpga) ----
add_interface s_hps avalon end
set_interface_property s_hps addressUnits SYMBOLS
set_interface_property s_hps associatedClock clk
set_interface_property s_hps associatedReset reset_n
set_interface_property s_hps burstOnBurstBoundariesOnly false
set_interface_property s_hps burstcountUnits WORDS
set_interface_property s_hps explicitAddressSpan 0
set_interface_property s_hps holdTime 0
set_interface_property s_hps linewrapBursts false
set_interface_property s_hps maximumPendingReadTransactions 1
set_interface_property s_hps maximumPendingWriteTransactions 0
set_interface_property s_hps readLatency 0
set_interface_property s_hps readWaitTime 0
set_interface_property s_hps setupTime 0
set_interface_property s_hps timingUnits Cycles
set_interface_property s_hps writeWaitTime 0
set_interface_property s_hps ENABLED true
set_interface_property s_hps EXPORT_OF ""
add_interface_port s_hps s_hps_address     address      Input  18
add_interface_port s_hps s_hps_read        read         Input   1
add_interface_port s_hps s_hps_write       write        Input   1
add_interface_port s_hps s_hps_writedata   writedata    Input  32
add_interface_port s_hps s_hps_readdata    readdata     Output 32
add_interface_port s_hps s_hps_readdatavalid readdatavalid Output 1
add_interface_port s_hps s_hps_waitrequest waitrequest  Output  1

# ---- 슬레이브 2: 가중치 로드 (hps2fpga) ----
# 스팬 0x100 (256B): 0x00 LOAD_ADDR / 0x04 LOAD_DATA (fpga_top_soc.sv 참고)
add_interface s_load avalon end
set_interface_property s_load addressUnits SYMBOLS
set_interface_property s_load associatedClock clk
set_interface_property s_load associatedReset reset_n
set_interface_property s_load burstOnBurstBoundariesOnly false
set_interface_property s_load burstcountUnits WORDS
set_interface_property s_load explicitAddressSpan 0
set_interface_property s_load holdTime 0
set_interface_property s_load linewrapBursts false
set_interface_property s_load maximumPendingReadTransactions 1
set_interface_property s_load maximumPendingWriteTransactions 0
set_interface_property s_load readLatency 0
set_interface_property s_load readWaitTime 0
set_interface_property s_load setupTime 0
set_interface_property s_load timingUnits Cycles
set_interface_property s_load writeWaitTime 0
set_interface_property s_load ENABLED true
set_interface_property s_load EXPORT_OF ""
add_interface_port s_load s_load_address      address      Input   8
add_interface_port s_load s_load_read         read         Input   1
add_interface_port s_load s_load_write        write        Input   1
add_interface_port s_load s_load_writedata    writedata    Input  32
add_interface_port s_load s_load_readdata     readdata     Output 32
add_interface_port s_load s_load_readdatavalid readdatavalid Output 1
add_interface_port s_load s_load_waitrequest  waitrequest  Output  1

# ---- 마스터: FPGA-to-HPS (f2h_axi_slave, read-only 64-bit) ----
# FT/PSQT 가중치를 HPS DDR3 에서 버스트 읽기. burstcount<=64 워드.
add_interface m_f2h avalon start
set_interface_property m_f2h addressUnits SYMBOLS
set_interface_property m_f2h associatedClock clk
set_interface_property m_f2h associatedReset reset_n
set_interface_property m_f2h burstOnBurstBoundariesOnly false
set_interface_property m_f2h burstcountUnits WORDS
set_interface_property m_f2h linewrapBursts false
set_interface_property m_f2h maximumPendingReadTransactions 1
set_interface_property m_f2h maximumPendingWriteTransactions 0
set_interface_property m_f2h readLatency 0
set_interface_property m_f2h ENABLED true
set_interface_property m_f2h EXPORT_OF ""
add_interface_port m_f2h m_f2h_address     address      Output 32
add_interface_port m_f2h m_f2h_read        read         Output  1
add_interface_port m_f2h m_f2h_burstcount  burstcount   Output  7
add_interface_port m_f2h m_f2h_readdata    readdata     Input  64
add_interface_port m_f2h m_f2h_readdatavalid readdatavalid Input  1
add_interface_port m_f2h m_f2h_waitrequest waitrequest  Input   1

# ---- 인터럽트 소스 (f2h_irq0) ----
add_interface irq_out interrupt sender
set_interface_property irq_out associatedClock clk
set_interface_property irq_out associatedReset reset_n
set_interface_property irq_out ENABLED true
set_interface_property irq_out EXPORT_OF ""
add_interface_port irq_out irq_out irq Output 1
