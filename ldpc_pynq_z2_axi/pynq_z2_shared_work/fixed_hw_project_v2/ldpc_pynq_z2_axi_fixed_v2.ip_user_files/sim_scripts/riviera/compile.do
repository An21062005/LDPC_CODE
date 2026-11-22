transcript off
onbreak {quit -force}
onerror {quit -force}
transcript on

vlib work
vlib riviera/xilinx_vip
vlib riviera/xpm
vlib riviera/xil_defaultlib

vmap xilinx_vip riviera/xilinx_vip
vmap xpm riviera/xpm
vmap xil_defaultlib riviera/xil_defaultlib

vlog -work xilinx_vip  -incr -l axi_vip_v1_1_23 -l processing_system7_vip_v1_0_25 -l smartconnect_v1_0 "+incdir+D:/vivado/2026.1/Vivado/data/xilinx_vip/include" -l xilinx_vip -l xpm -l xil_defaultlib \
"D:/vivado/2026.1/Vivado/data/xilinx_vip/hdl/axi4stream_vip_axi4streampc.sv" \
"D:/vivado/2026.1/Vivado/data/xilinx_vip/hdl/axi_vip_axi4pc.sv" \
"D:/vivado/2026.1/Vivado/data/xilinx_vip/hdl/xil_common_vip_pkg.sv" \
"D:/vivado/2026.1/Vivado/data/xilinx_vip/hdl/axi4stream_vip_pkg.sv" \
"D:/vivado/2026.1/Vivado/data/xilinx_vip/hdl/axi_vip_pkg.sv" \
"D:/vivado/2026.1/Vivado/data/xilinx_vip/hdl/axi4stream_vip_if.sv" \
"D:/vivado/2026.1/Vivado/data/xilinx_vip/hdl/axi_vip_if.sv" \
"D:/vivado/2026.1/Vivado/data/xilinx_vip/hdl/clk_vip_if.sv" \
"D:/vivado/2026.1/Vivado/data/xilinx_vip/hdl/rst_vip_if.sv" \

vlog -work xpm  -incr -l axi_vip_v1_1_23 -l processing_system7_vip_v1_0_25 -l smartconnect_v1_0 "+incdir+D:/vivado/2026.1/Vivado/data/rsb/busdef" "+incdir+../../../../fixed_rtl_source/permutations" "+incdir+../../../../fixed_rtl_source/Utilities" "+incdir+../../../../fixed_rtl_source/CNU" "+incdir+../../../../fixed_rtl_source/VNU" "+incdir+../../../../fixed_rtl_source/PE_block" "+incdir+../../../../fixed_rtl_source/memory" "+incdir+../../../../fixed_rtl_source/address_generator" "+incdir+../../../ldpc_pynq_z2_axi_fixed_v2.gen/sources_1/bd/ldpc_system/ipshared/ec67/hdl" "+incdir+../../../ldpc_pynq_z2_axi_fixed_v2.gen/sources_1/bd/ldpc_system/ipshared/df05/hdl" "+incdir+../../../ldpc_pynq_z2_axi_fixed_v2.gen/sources_1/bd/ldpc_system/ipshared/f0b6/hdl/verilog" "+incdir+../../../ldpc_pynq_z2_axi_fixed_v2.gen/sources_1/bd/ldpc_system/ipshared/00fe/hdl/verilog" "+incdir+D:/vivado/2026.1/Vivado/data/xilinx_vip/include" -l xilinx_vip -l xpm -l xil_defaultlib \
"D:/vivado/2026.1/Vivado/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv" \

vcom -work xpm -93  -incr \
"D:/vivado/2026.1/Vivado/data/ip/xpm/xpm_VCOMP.vhd" \

vlog -work xil_defaultlib  -incr -l axi_vip_v1_1_23 -l processing_system7_vip_v1_0_25 -l smartconnect_v1_0 "+incdir+D:/vivado/2026.1/Vivado/data/rsb/busdef" "+incdir+../../../../fixed_rtl_source/permutations" "+incdir+../../../../fixed_rtl_source/Utilities" "+incdir+../../../../fixed_rtl_source/CNU" "+incdir+../../../../fixed_rtl_source/VNU" "+incdir+../../../../fixed_rtl_source/PE_block" "+incdir+../../../../fixed_rtl_source/memory" "+incdir+../../../../fixed_rtl_source/address_generator" "+incdir+../../../ldpc_pynq_z2_axi_fixed_v2.gen/sources_1/bd/ldpc_system/ipshared/ec67/hdl" "+incdir+../../../ldpc_pynq_z2_axi_fixed_v2.gen/sources_1/bd/ldpc_system/ipshared/df05/hdl" "+incdir+../../../ldpc_pynq_z2_axi_fixed_v2.gen/sources_1/bd/ldpc_system/ipshared/f0b6/hdl/verilog" "+incdir+../../../ldpc_pynq_z2_axi_fixed_v2.gen/sources_1/bd/ldpc_system/ipshared/00fe/hdl/verilog" "+incdir+D:/vivado/2026.1/Vivado/data/xilinx_vip/include" -l xilinx_vip -l xpm -l xil_defaultlib \
"../../../../fixed_rtl_source/Decoder.v" \
"../../../../fixed_rtl_source/LDPC_Decoder_PYNQ_Z2_top.sv" \

vlog -work xil_defaultlib \
"glbl.v"

