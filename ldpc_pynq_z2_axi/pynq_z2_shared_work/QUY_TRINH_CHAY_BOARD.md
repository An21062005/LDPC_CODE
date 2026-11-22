# Chạy LDPC trên PYNQ-Z2 (bitstream cũ/raw)

Dùng bitstream cũ trong `deploy/`, không cần build Vivado.
Nếu board đã có `input.txt` và runner raw cũ, chạy **2 → 3 → 4 → 5**.
Serial: **COM4, 115200 baud, 8N1, flow control None**.

## Chuẩn bị trên Windows

Mở PowerShell tại thư mục dự án:

```powershell
Set-Location -LiteralPath 'C:\Users\HOANG AN\Downloads\ldpc_pynq_z2_axi'
```

COM4 chỉ dùng được bởi một chương trình: đóng phiên Serial MobaXterm trước
khi gửi/tải bằng PowerShell; mở lại khi chạy lệnh trên board.
Giữ nguyên `Loc`; chỉ dùng `/home/xilinx/pynq_z2_shared_work` cùng cấp với `Loc`.

## 1. Gửi input và runner raw lên board (nếu chưa có)

Trong MobaXterm, đăng nhập `xilinx` rồi kiểm tra đích:

```bash
ls -la /home/xilinx
ls -ld /home/xilinx/pynq_z2_shared_work
readlink -f /home/xilinx/pynq_z2_shared_work
ls -la /home/xilinx/pynq_z2_shared_work
```

Chỉ gửi khi đích thực là `/home/xilinx/pynq_z2_shared_work`, cùng cấp với
`Loc` (không phân biệt hoa/thường). Nếu chưa xác định được, dừng để kiểm tra.

Mở `pynq_z2_shared_work/tools/transfer_benchmark_uart.ps1`,
sửa hai dòng đầu rồi **Ctrl+S**:

```powershell
$SourceFolder = 'C:\Users\HOANG AN\Downloads\ldpc_pynq_z2_axi\pynq_z2_shared_work\board_uploads_raw'
$DestinationFolder = '/home/xilinx/pynq_z2_shared_work'
```

`board_uploads_raw` đã có `input.txt` (698 frame) và
`run_ldpc_full_benchmark.py` bản cũ từ `archive/old_scripts/`.
**Không chọn `board_uploads`: runner ở đó dùng cho COD1.**

Đóng Serial MobaXterm, chạy trong PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\pynq_z2_shared_work\tools\transfer_benchmark_uart.ps1 -ComPort COM4
```

Đợi `BOARD_SEND_ALL_OK`. Nếu báo `Refusing to overwrite different existing file`,
dừng kiểm tra file đang có; không xóa/ghi đè để vượt kiểm tra.

## 2. Nạp lại bitstream trước mỗi lần benchmark

Vivado: **Open Hardware Manager → Open Target → Auto Connect**.
Kiểm tra đúng thiết bị **`xc7z020_1`**, chọn **Program Device** với file:

```text
C:\Users\HOANG AN\Downloads\ldpc_pynq_z2_axi\pynq_z2_shared_work\deploy\ldpc_pynq_z2_fixed.bit
```

Debug probes để trống → **Program** → đợi **Programmed / startup HIGH**.
Nạp JTAG volatile; không ghi flash, boot image hay format microSD.
Nạp lại mỗi lần để bộ đếm frame về 0.

## 3. Chạy benchmark trên board

Mở lại MobaXterm COM4, chạy từng dòng:

```bash
cd /home/xilinx/pynq_z2_shared_work
ls -l -- input.txt run_ldpc_full_benchmark.py
sudo -E /usr/local/share/pynq-venv/bin/python3 run_ldpc_full_benchmark.py
```

Chờ khoảng 20 giây. Log cần có:

```text
OUTPUT_FRAMES=696
RESULT_DIRECTORY=/home/xilinx/pynq_z2_shared_work/python_benchmark_<thoi_gian_lan_chay>
```

Giữ đường dẫn `RESULT_DIRECTORY` để tải ở bước 4.
Nếu báo `Reprogram your existing fixed bitstream before this benchmark`,
nạp lại ở bước 2 rồi chạy lại.

## 4. Tải kết quả về Windows

Mở `pynq_z2_shared_work/tools/download_benchmark_uart.ps1`,
sửa hai dòng đầu rồi **Ctrl+S**. `$SourceFolder` là nguyên đường dẫn
`RESULT_DIRECTORY` của lần vừa chạy (thay phần `<thoi_gian_lan_chay>`):

```powershell
$SourceFolder = '/home/xilinx/pynq_z2_shared_work/python_benchmark_<thoi_gian_lan_chay>'
$DestinationFolder = 'C:\Users\HOANG AN\Downloads\ldpc_pynq_z2_axi\pynq_z2_shared_work\board_downloads'
```

Đóng Serial MobaXterm, chạy trong PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\pynq_z2_shared_work\tools\download_benchmark_uart.ps1 -ComPort COM4
```

Đợi `BENCHMARK_DOWNLOAD_OK`. **Copy đường dẫn sau `LOCAL_DESTINATION=`**
để dùng ngay ở bước 5. Mỗi lần tải tạo thư mục mới, gồm:

- `output_raw.txt`: output FPGA, 696 frame × 1152 bit.
- `summary.json`: thời gian và throughput.
- `transactions.csv`: thời gian từng transaction.

## 5. Compare expected với output vừa tải

**Chạy trên Windows, trong PowerShell tại thư mục dự án.**
Thay chuỗi `DAN_DUONG_DAN_LOCAL_DESTINATION_VAO_DAY` bằng đường dẫn
vừa copy ở bước 4 (chỉ phần sau dấu `=`):

```powershell
$Downloaded = 'DAN_DUONG_DAN_LOCAL_DESTINATION_VAO_DAY'
$Actual = Join-Path $Downloaded 'output_raw.txt'
python .\pynq_z2_shared_work\tools\compare_board_to_clean.py --raw --expected .\pynq_z2_shared_work\FINAL_REPORT_PACKAGE\results\expected_codeword.txt --actual $Actual
```

Kết quả đúng:

```text
EXPECTED_FRAMES=696
ACTUAL_FRAMES=696
BIT_ERRORS=0
BAD_FRAMES=0
BER=0
RESULT=PASS
```

`--raw` đổi thứ tự bit trong bộ nhớ để so với expected, không sửa output.
Luôn truyền `--actual` để so đúng lần vừa tải. Lệnh benchmark không so expected;
`bit_errors`, `bad_frames`, `ber` trong `summary.json` vẫn là `null`.
Compare trên Windows không cập nhật file đó.

## Ghi chú

- `Access to COM4 is denied`: đóng phiên Serial đang giữ COM4 rồi chạy lại.
- COD1 để sửa sau: `fixed_rtl_source/LDPC_Decoder_PYNQ_Z2_top.sv` và
  `fixed_hw_project_v2/ldpc_pynq_z2_axi_fixed_v2.xpr`. Mô phỏng thứ tự output
  PASS; implementation 07/10/2026 chưa đạt timing (WNS −0,579 ns, 28 endpoint).
  Quy trình này dùng bitstream cũ trong `deploy/`.
- Khi chuyển sang COD1, so `output_codeword.txt` và bỏ `--raw`.
