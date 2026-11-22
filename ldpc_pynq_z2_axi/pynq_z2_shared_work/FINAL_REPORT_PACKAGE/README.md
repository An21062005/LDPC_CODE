# PYNQ-Z2 LDPC final report package

Đây là bộ file lưu trữ của bitstream raw trước bản COD1. Kết quả đã được
kiểm tra trên PYNQ-Z2 với 696 codeword (801,792 bit): 0 bit lỗi, BER = 0.

## File cần thiết

- `hardware/ldpc_pynq_z2_fixed.bit`: bitstream đã sửa, nạp volatile bằng Vivado JTAG.
- `hardware/ldpc_pynq_z2_fixed.hwh`: mô tả phần cứng đi kèm.
- `rtl/`: toàn bộ RTL đã sửa và testbench AXI.
- `data/input.txt.gz`: 698 frame đầu vào, gồm 696 payload và 2 flush frame.
- `results/output_fixed_full_board.txt`: raw output tải trực tiếp từ board.
- `results/expected_codeword.txt`: codeword sạch dùng làm tham chiếu BER.
- `scripts/`: các script lưu trong gói báo cáo. Công cụ hiện dùng nằm ở `../tools/`.
- `reports/`: trạng thái kiểm thử, timing và CDC; log tạo/nạp bitstream đã được dọn.
- `SHA256SUMS.txt`: SHA-256 của mọi file trong gói.

## Compare hiện tại cho output COD1 mới

RTL đang sửa nằm trong `../fixed_rtl_source/`; Python gửi lên board nằm trong
`../board_uploads/`. Sau khi build và chạy lại bản COD1, công cụ compare ở
`../tools/compare_board_to_clean.py` so trực tiếp file `output_codeword.txt` với
`results/expected_codeword.txt`. Sửa `ACTUAL` ở đầu file compare tới lần tải mới,
rồi chạy tại thư mục này:

```powershell
python ..\tools\compare_board_to_clean.py
```

Kết quả đúng:

```text
EXPECTED_FRAMES=696
ACTUAL_FRAMES=696
REFERENCE_BITS=801792
BIT_ERRORS=0
BAD_FRAMES=0
BER=0
RESULT=PASS
```

`results/output_fixed_full_board.txt` trong gói này là raw output cũ: thứ tự bit
khác expected. Kết quả BER = 0 của gói được kiểm tra bằng phép đổi thứ tự trước
đây. Công cụ compare hiện tại dành cho COD1 mới, không hoán vị các bit raw cũ.

## Lưu ý phần cứng

Bitstream `hardware/ldpc_pynq_z2_fixed.bit` là bản raw lịch sử của gói này.
Để dùng Python COD1 mới, build project `../fixed_hw_project_v2/` và chọn file
`ldpc_system_wrapper.bit` vừa tạo. Nạp vào `xc7z020_1` bằng Vivado Hardware Manager.
Đây là cấu hình JTAG volatile nên mất khi tắt nguồn. Không ghi QSPI/flash và
không sửa microSD.
