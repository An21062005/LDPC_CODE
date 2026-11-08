# ldpc_da2_configurable — so sánh Serial / Partly-Parallel / Fully-Parallel

Đồ án 2: cùng mã (1152,580) của `ldpc_da2`, ba kiến trúc chọn trước khi tổng
hợp, mỗi kiến trúc mô phỏng và build PYNQ-Z2 riêng. Dự án chạy độc lập: mọi
RTL/dữ liệu cần thiết nằm trong `code/`, mọi kết quả nằm trong `outfeed/`.

## 1. Những gì đã xác minh từ `ldpc_da2`

| Mục | Giá trị thực tế (đọc từ RTL/dữ liệu, kiểm bằng `run.py check`/`model`) |
|---|---|
| H | `code/data/H_np_array.npy`, 576×1152, (3,6)-regular, rank 572 → k = 580 |
| Ánh xạ bit | mẫu vào n = cột n của H = PE `n/32` (cột-major), địa chỉ `n%32` |
| Thuật toán | sum-product dạng φ: VNU cộng (bù 2), CNU cộng φ (LUT.v), dấu XOR |
| Lượng tử | vào 5 bit bù 2 (2.2, bão hòa ±3.75); CN→VN 5 bit dấu-độ lớn; VN→CN 6 bit {hd, dấu, φ} |
| Cộng | 7 bit, không tràn với bậc 3/6; LUT.v 7 bit vào → 4 bit; chỉ số ≥ 64 → 0 |
| Lịch | flooding; mỗi vòng = pha VN rồi pha CN; CN→VN = 0 ở pha VN đầu |
| Số vòng | 18 (PE_block: `itr_count` 0..35 = 36 pha) |
| Dừng | luôn chạy đủ 18 vòng; quyết định **đóng băng** sau pha CN đầu tiên có syndrome 0 |
| Giao tiếp | AXI4-Lite COD1, trễ 2 transaction (nạp t, giải t−1, trả t−2) |
| Clock lõi | 30 MHz (MMCM từ FCLK 100 MHz); bản 36 PE dùng thêm 60 MHz cho RAM |

`script/ldpc_common.py` là mô hình Python bit-accurate của các điểm trên (bảng
LUT đọc trực tiếp từ `LUT.v`). Nó chỉ dùng để **đối chiếu** đầu ra mô phỏng,
không sinh đầu ra DUT. `script/gen_data.py --verify-reference` tái tạo đúng
từng byte `input.txt`/`expected_codeword.txt` của da2 từ `eye.png`.

## 2. Ba kiến trúc

| | Serial | Partly-Parallel (mốc) | Fully-Parallel |
|---|---|---|---|
| RTL lõi | `code/rtl/serial/ldpc_core_serial.sv` | `code/rtl/da2_core/` (bản sao da2, đã sửa 2 file — mục 5) | `code/rtl/fully_parallel/ldpc_core_fp.sv` |
| PE | 1 VNU + 1 CNU dùng lại cho mọi nút | 36 PE_BLOCK, mỗi PE = 1 VNU + RAM của 32 VN | mỗi VN 1 VNU, mỗi CN 1 CNU |
| Số VNU / CNU | 1 / 1 | 36 / 18 | 1152 / 576 |
| Mức song song | 1 nút/lần; bộ nhớ message 1 đọc + 1 ghi/clock | 36 VN hoặc 18 CN mỗi clock, 32 địa chỉ/pha | mọi nút cùng lúc |
| Bộ nhớ message | RAM 3456×6 (thứ tự VN), ROM thứ tự CN | 3 EXT_RAM 32×6 mỗi PE (clk_df) | thanh ghi 3456×5 + đầu ra VNU |
| Kết nối | ROM `serial_rom.v` sinh từ H | PI_1/PI_2/PI_3 + bộ sinh địa chỉ | dây cứng theo H (bảng trong `ldpc_code_pkg.sv`) |
| Chu kỳ/vòng | ≈ 2×3456 + đường ống | ≈ 78 | 4 (VA, VB, CN, CP) |
| Clock | 30 MHz | 30 MHz + 60 MHz (RAM) | 30 MHz |

Cả ba dùng cùng số học: Serial/FP gọi nguyên `VNU.v`, `CNU.v`, `LUT.v`,
`S_to_T.v`, `T_to_S.v`, `full_adder.v`, `6-bit-ripple_carry_adder.v` của da2
qua adapter `code/rtl/common/node_units.sv`. Fully-Parallel không giải xong
trong một clock: mỗi vòng 4 clock, 18 vòng.

Serial và FP dùng chung wrapper `code/rtl/wrapper/ldpc_axi_top.sv`: cùng bản
đồ thanh ghi, cùng trễ 2 transaction và cùng clock 30 MHz như da2, nên test
AXI và `run_board.py` dùng chung cho cả ba. Wrapper này chép kết quả sang miền
AXI khi `done`, nên có thêm 1152 FF so với da2; đó là chi phí của wrapper,
không thuộc lõi. Báo cáo tài nguyên tách riêng lõi (`core` / `decoder_core`).

## 3. Lệnh (chạy trong `ldpc_da2_configurable`)

```powershell
python script/run.py check                       # H, LUT, filelist, RTL sinh ra, Vivado
python script/run.py list                        # kiến trúc, test, profile sóng
python script/run.py data                        # tạo bộ dữ liệu nhiễu (outfeed/data)
python script/run.py model --test noisy          # mô hình Python, không Vivado
python script/run.py sim --arch serial --test regression
python script/run.py sim --arch fully_parallel --test noisy --waves core
python script/run.py sim --arch partly_parallel --test regression --waves overview --gui
python script/run.py wave --arch serial --test noisy          # mở sóng đã lưu
python script/run.py project --arch serial --gui               # chỉ tạo project
python script/run.py build --arch serial                       # synth, impl, bitstream
python script/run.py package --arch serial                     # đánh giá lại, đóng gói
python script/run.py report                                    # outfeed/reports/comparison.md
python script/gen_rtl.py [--check]                             # sinh lại bảng từ H
```

`--arch`: `serial`, `partly_parallel`, `fully_parallel`. `--dry-run` in cấu
hình đã resolve, không chạy Vivado. Không lệnh nào kết nối hay nạp FPGA.

### Test

| `--test` | Loại | Dữ liệu | Kiểm |
|---|---|---|---|
| `smoke` | AXI | gốc (SNR 20 dB) | 3 transaction, 1 codeword |
| `regression` | AXI | gốc | 5 transaction, 3 codeword (như da2) |
| `noisy` | AXI | SNR 3 dB, seed 42, ~8% bit lỗi kênh | 20 codeword = codeword sạch **và** = mô hình bit-accurate |
| `full` | AXI | gốc | 696 codeword; chạy lâu |
| `core` | lõi (không AXI) | SNR 3 dB | Serial/FP: giải mã + thứ tự + chu kỳ giải mã |
| `order` | AXI | 696 frame raw da2 đã ghi | chỉ bản 36 PE: thứ tự đầu ra của wrapper |

Dữ liệu gốc của da2 không có lỗi kênh (input bão hòa ±3.75, hard-decision =
codeword), nên chỉ kiểm được vòng lặp đầu. Bộ `noisy` dùng đúng ảnh và luồng
tạo dữ liệu, chỉ hạ SNR để decoder phải sửa lỗi qua nhiều vòng; cùng dữ liệu
và cùng tiêu chí cho cả ba kiến trúc.

`code/tests/tb_axi.sv` là `tb_da2.sv` của da2, chỉ đổi timeout toàn cục và
giới hạn số lần poll thành plusarg (Serial cần ~4 ms/frame). `run.py` tính
hai giá trị này theo số frame và `txn_cycles_max` (chu kỳ/transaction đo bằng
`core_monitor`) của từng kiến trúc, dư 2 lần; chúng chỉ chặn treo, không phải
tiêu chí PASS. `tb_axi.sv` chờ theo bước 1 µs để không tràn delay 32 bit
(lỗi này làm hai lần `full` Serial trước bị "global simulation timeout"). `core_monitor.sv`
chỉ đo chu kỳ giải mã, không lái tín hiệu. `tb_core.sv` lái trực tiếp lõi.

### Trình mô phỏng

- XSim chạy độc lập (`xvlog`/`xelab`/`xsim`). `launch_simulation` của project
  mode báo `Spawn failed` trên máy này kể cả với project rỗng, nên không dùng.
- XSim bản BASIC từ chối thiết kế > 50 000 instance; FP có ~146 000 (cổng của
  `full_adder.v`). FP vì vậy chạy QuestaSim (`questa.bin` trong `config.yaml`);
  test AXI biên dịch thêm `MMCME2_*`, `BUFG`, `xpm_memory` từ thư mục Vivado.
  Đổi trình mô phỏng: `--sim xsim|questa`.

- `full` của Serial chạy bằng Questa (`--sim questa`, nhanh hơn XSim ~3 lần);
  cùng testbench, cùng RTL.

### RTL sinh từ H

`script/gen_rtl.py` sinh `code/rtl/generated/ldpc_code_pkg.sv` (hằng số mã +
bảng VN_PTR/CN_PTR/CN_EDGE) và `serial_rom.v` (ROM `case` có thanh ghi → BRAM).
RTL tổng hợp `import ldpc_code_pkg::*` thay cho `include`: bộ phân tích HDL
của module reference trong block design không tìm được header khi build FP,
và tham số module top phải là hằng số, nên `N` của wrapper là `localparam`.
`gen_rtl.py --check` báo nếu file sinh ra không khớp H.

### Sóng

`--waves none|overview|axi|core|all`. Nhóm tín hiệu trong `config.yaml`
(`waveforms`). XSim lưu `waves.wdb` + `waves.wcfg`; Questa lưu `vsim.wlf` +
`wave.do`. `wave` mở lại không mô phỏng lại.

## 4. Build và điều kiện "sẵn sàng nạp board"

`build` tạo block design như da2 (PS7 → SmartConnect → decoder ở 0x43C00000,
FCLK 100 MHz), chạy synth/impl/bitstream, ghi `reports/` (tài nguyên tổng và
theo cấp, timing, slack theo từng clock, công suất `report_power` — **ước
tính**, không phải đo trên board). Không có ràng buộc XDC thêm cho kiến trúc
nào (giống da2). Gói `outfeed/artifacts/` chỉ được tạo khi đồng thời: có
bitstream, WNS ≥ 0 và WHS ≥ 0, `regression` và `noisy` PASS trên **cùng**
SHA-256 RTL. Fmax ước tính = 1/(T − slack nội clock); chưa chạy quét clock.

## 5. Bản 36 PE: lỗi của da2 và phần đã sửa trong bản sao

`ldpc_da2/code/rtl` giữ nguyên. Bản sao `code/rtl/da2_core` **không còn
byte-identical**: hai file có khối chú thích `FIX (ldpc_da2_configurable)`.
Mọi file khác (lõi, PE, CNU/VNU, PI, RAM, H, số học, 18 vòng, 36 PE/18 CNU,
30/60 MHz, COD1) giữ nguyên.

| Lỗi trong da2 | Bằng chứng | Sửa trong bản sao |
|---|---|---|
| Đường chụp kết quả `sample_toggle` (cạnh lên `decoder_clk`) được lấy mẫu ở cạnh xuống `clk_df` **cùng thời điểm** (MMCM lệch 90°) | số lần ghi `output_blocks` mỗi transaction 64, 0, 32, 64, 0; frame sai trùng codeword frame trước; `full` sai 199/696 frame | `LDPC_Decoder_PYNQ_Z2_top.sv`: chụp ở cạnh lên `clk_df` khi `clk` thấp, khối `(transfer_count−1)/6` khi `(transfer_count−1)%6 = 5`: đúng 32 lần ghi, đủ 32 địa chỉ |
| Mux đọc AXI đọc thẳng `output_blocks` (miền 60 MHz) → đường liên miền | WNS −0,579 ns ở nhóm `clk_fpga_0` | thêm `codeword_axi` ở miền AXI, chép khi `busy` đồng bộ = 0 (dữ liệu tĩnh) |
| `logic last_f_id;` 1 bit so với `temp_f_id` 36 bit | đóng băng không bao giờ bật khi `rs=1` | `Decoder.v`: `logic [(K*K)-1:0] last_f_id;` |

Kiểm tra sau sửa (probe mô phỏng trong `outfeed/debug/pp_fix2_probe_*`):
32 lần ghi/transaction ở cả hai bank; vòng đóng băng của RTL trùng `frozen_at`
của mô hình ở 20/20 frame nhiễu (cả `rs=0` và `rs=1`). Kết quả test/build mới
nhất: `outfeed/reports/`.
