# Fixed RTL and Vivado simulation

This directory is an isolated copy of the corrected RTL. The original source
files in the parent directory are unchanged.

## Run the module tests

From this `fix` directory in PowerShell:

```powershell
python run_unit_tests.py
```

The runner tests the arithmetic utilities, RAM/address generator, CNU, VNU,
and all three shuffle/unshuffle pairs with Vivado XSim.

## Run the complete decoder

```powershell
python run_rtl.py --simulator vivado --input input.txt --output output.txt
C:\miniconda\python.exe ..\compare.py --expected ..\expected_codeword.txt --actual output.txt
```

Vivado 2026.1 is detected automatically at
`D:\vivado\2026.1\Vivado\bin`. You can also select it explicitly:

```powershell
$env:VIVADO_BIN="D:\vivado\2026.1\Vivado\bin"
```

## Inject channel sign errors for decoder testing

This does not modify the original `input.txt`:

```powershell
python tests\make_error_input.py ..\input.txt tests\input_5errors.txt 7 100 333 700 1001
python run_rtl.py --simulator vivado --input tests\input_5errors.txt --output tests\output_5errors.txt
C:\miniconda\python.exe ..\compare.py --expected ..\expected_codeword.txt --actual tests\output_5errors.txt
```

## Main RTL corrections

- Correct packed ranges and lane ordering for Vivado/SystemVerilog.
- Correct CNU/VNU signed arithmetic and widen intermediate sums to seven bits.
- Correct hard-decision bit selection and initialize pipeline/RAM outputs.
- Hold the synchronous address-generator reset across a real clock edge.
- Align the PI3 shuffle state with the 32 QC-LDPC addresses.
- Increase the CNU return-address pipeline to eight stages so messages are
  written back to the matching variable-node address.
- Stop overwriting decision RAM after a complete zero-syndrome CNU phase.
- Clear one-hot testbench selectors on every transfer.

## Verification evidence

The latest end-to-end run used the 224x225 eye image and completed 696 payload
frames (801,792 reference bits).  The exported evidence is kept in the parent
directory `verification_logs/`:

- `01_generate_input.log`: generated-input metadata for step 1.
- `02_run_rtl_detailed.log`: combined Vivado xvlog/xelab/xsim output for step 2.
- `03_compare_detailed.log`: PASS summary plus results for all 696 frames.
- `01_test_metadata.json`, `02_raw_*`, and `03_compare_report.json`: raw artifacts.

The final comparison is 0 bit errors, 0 unknown X/Z bits, BER 0, PASS.

## PYNQ-Z2 hardware wrapper

`LDPC_Decoder_PYNQ_Z2_top.sv` keeps `LDPC_Decoder` unchanged and adds an
AXI4-Lite frame buffer/controller. AXI is an internal connection between the
Zynq ARM processing system and programmable logic; it is not an external
cable. The board boots PYNQ Linux from microSD and the overlay is copied over
Ethernet/USB networking. Micro-USB/JTAG may also program the PL from Vivado.
The AXI/PS clock remains 100 MHz; the wrapper generates timing-safe 30/60 MHz
related clocks for the unchanged decoder core.

Create the hardware project from the Vivado GUI with **Tools > Run Tcl Script**
and select `create_pynq_z2_axi_project.tcl`. Then run Synthesis,
Implementation, and Generate Bitstream. Copy the resulting `.bit` and `.hwh`
files with `pynq_ldpc.py` to the board. The software driver loads 1152 five-bit
samples through AXI4-Lite, starts the hardware sequencer, waits for completion,
and reads 1152 hard-decision bits.

The included `board_files_repo` directory supplies the PYNQ-Z2 PS/DDR preset
locally; it is referenced by the project script and does not alter the Vivado
installation.

### Verified PYNQ-Z2 build

Vivado 2026.1 completed synthesis, implementation, routing, and bitstream
generation for `xc7z020clg400-1`. Final post-route results:

- AXI wrapper regression: 3 frames, all 1152 output bits matched.
- Timing: WNS +0.206 ns, WHS +0.050 ns; all constraints met.
- Routing: 42,627/42,627 routable nets fully routed; 0 routing errors.
- DRC: 0 checks; Methodology: 0 checks.
- Utilization: 48.62% LUT, 25.18% registers, 0.36% BRAM.
- Vectorless estimated on-chip power: 1.829 W.

The ready-to-copy board files and full reports are in `artifacts/pynq_z2/`.
