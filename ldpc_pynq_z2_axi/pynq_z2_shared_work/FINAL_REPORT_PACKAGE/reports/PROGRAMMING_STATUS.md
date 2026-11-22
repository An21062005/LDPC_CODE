# FPGA programming status

- Date: 2026-09-27
- Board: PYNQ-Z2
- JTAG target: `localhost:3121/xilinx_tcf/Xilinx/1234-tulA`
- FPGA device: `xc7z020_1`
- Bitstream: `deploy/ldpc_pynq_z2.bit`
- SHA-256: `28CEEC9010D66A9CCCBCF46D71C8DCDC579A3B841CC4A976DCFAD14715E2EA25`
- Vivado result: `SAFE_PROGRAM_SUCCESS=1`
- Startup status: `HIGH`
- Configuration type: volatile JTAG programming only
- Flash programmed: no
- microSD modified: no
- Protected `Loc` directory accessed or modified: no

## Live hardware test

- Test path: UART console -> PYNQ Linux -> AXI-Lite at `0x43C00000`
- Frame 1 status: `0x0001000a`
- Frame 2 status: `0x00020002`
- Frame 3 status: `0x0003000e`
- Output-valid asserted on frame 3: yes
- Output length: 1152 bits
- Board result: `LIVE_LDPC_TEST_PASS`
- Board output: `/home/xilinx/pynq_z2_shared_work/output_first_valid.txt`
- Expected first-line SHA-256: `6df6f4b556b19151f021495b4395c8c387142d8c22b437f5394238a9c60f0d34`
- Observed board-output SHA-256: `3f882b7b3a0c55f32c61d24547090a4aa176780ab21bc1e32f5cee89a32ee7a7`
- Bit-for-bit reference comparison: mismatch; investigation required
- Live-vs-reference mismatches: 27 of 1152 bits
- Closest reference frame: line 1 (27 mismatches); no exact match in 696 reference frames
- Fresh 3-frame RTL simulation SHA-256: `6df6f4b556b19151f021495b4395c8c387142d8c22b437f5394238a9c60f0d34`
- Fresh RTL simulation vs stored reference: 0 mismatches
- Live hardware vs fresh RTL simulation: 27 mismatches

## Synthesis-safe fix and new volatile configuration

- Root cause: `PE_block.v` used internal high-impedance (`5'bz`) addresses as pipeline bubbles; synthesis converted those don't-care values into real RAM addresses while write-enable remained asserted.
- Fix: explicit VNU/CNU address-valid pipelines now suppress EXT/DEC RAM writes during flush bubbles; invalid addresses are driven to zero instead of `Z`.
- Original RTL/project modified: no
- Fixed RTL copy: `fixed_rtl_source/`
- Behavioral AXI regression: 1152/1152 output bits matched
- Post-synthesis functional netlist regression: 1152/1152 output bits matched
- Full synthesis: 0 errors, 0 critical warnings
- Routed setup slack WNS: `+0.052 ns`
- Routed hold slack WHS: `+0.016 ns`
- Routed failed/unrouted nets: 0
- Fixed bitstream: `deploy/ldpc_pynq_z2_fixed.bit`
- Fixed bitstream SHA-256: `3FBDE736B636B28FA4039C1E01C37CEE941C17F64D745C288022E54B3A71CE1F`
- JTAG target verified: `localhost:3121/xilinx_tcf/Xilinx/1234-tulA`
- FPGA device verified: `xc7z020_1`
- Volatile JTAG programming: success
- FPGA DONE after programming: `1`
- Flash programmed: no
- microSD modified: no
- Protected `Loc` directory accessed or modified: no
- Manual Vivado JTAG programming after power cycle: success
- New live-board test: `LIVE_LDPC_TEST_PASS`
- New live-board output length: 1152 bits
- New live-board output: `/home/xilinx/pynq_z2_shared_work/output_fixed_manual1.txt`
- New live-board SHA-256: `6df6f4b556b19151f021495b4395c8c387142d8c22b437f5394238a9c60f0d34`
- New live-board output vs RTL/reference: exact match (0 mismatches)

## Full dataset hardware validation

- Input frames sent to board: 698 (696 payload + 2 pipeline flush frames)
- Output frames received: 696
- Board result: `FULL_LDPC_TEST_PASS`
- Board output: `/home/xilinx/pynq_z2_shared_work/output_fixed_full.txt`
- Windows copy: `pynq_z2_shared_work/output_fixed_full_board.txt`
- Board/Windows output SHA-256: `bf2ebae9981fee44a444dcf23682e3bd0f477e8446f81440bd87477487e81bd2`
- Clean reference: `expected_codeword.txt` from the original decoder dataset
- Comparison method: convert each raw board frame with `raw_frame_to_codeword`, then compare bit by bit
- Expected frames: 696
- Actual frames: 696
- Reference bits: 801,792
- Bit errors: 0
- Bad frames: 0
- Unknown X/Z bits: 0
- BER: 0
- Final result: `PASS`
