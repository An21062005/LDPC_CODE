onbreak {quit -f}
onerror {quit -f}

vsim  -lib xil_defaultlib LDPC_Decoder_PYNQ_Z2_top_opt

set NumericStdNoWarnings 1
set StdArithNoWarnings 1

do {wave.do}

view wave
view structure
view signals

do {LDPC_Decoder_PYNQ_Z2_top.udo}

run 1000ns

quit -force
