transcript off
onbreak {quit -force}
onerror {quit -force}
transcript on

asim +access +r +m+LDPC_Decoder_PYNQ_Z2_top  -L xil_defaultlib -L xilinx_vip -L xpm -L xilinx_vip -L unisims_ver -L unimacro_ver -L secureip -O5 xil_defaultlib.LDPC_Decoder_PYNQ_Z2_top xil_defaultlib.glbl

do {LDPC_Decoder_PYNQ_Z2_top.udo}

run 1000ns

endsim

quit -force
