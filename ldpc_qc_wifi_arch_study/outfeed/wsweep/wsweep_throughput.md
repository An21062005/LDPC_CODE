# Thông lượng các kiến trúc giải mã LDPC 802.11n

Sinh lúc 2026-11-22T07:21:57+00:00 bởi `python script/wsweep_report.py`.

## 1. Công thức

Ký hiệu: N = độ dài codeword, K = số bit thông tin, R = K/N, Z = kích thước khối QC, E = số cạnh của H, I = 18 vòng lặp (cố định, không dừng sớm), W = số mẫu nạp / bit đọc mỗi chu kỳ, f = tần số clock lõi.

| Đại lượng | Công thức | Ghi chú |
|---|---|---|
| Chu kỳ giải mã D, Fully-parallel | D = 4·I = 72 | 4 chu kỳ / vòng lặp, không phụ thuộc mã |
| Chu kỳ giải mã D, Partly-parallel | D = I·(2Z + 6) | pha VN Z+3, pha CN Z+2, EVAL 1 |
| Chu kỳ giải mã D, Serial | D ≥ I·2E | 1 cạnh / chu kỳ mỗi pha; đo thực tế cao hơn < 1 % (chờ FIFO) |
| Chu kỳ / transaction T | T = max(D + 2, N/W + 3) | nạp frame mới song song với giải mã frame trước |
| Thông lượng codeword | Θc = N·f / T | Mb/s khi f tính bằng MHz |
| Thông lượng thông tin | Θi = K·f / T = R·Θc | |
| Thời gian một transaction | L = T / f | µs khi f tính bằng MHz; kết quả một frame ra sau 2 transaction |
| Tăng tốc theo W | S(W) = T(1) / T(W) | |

Tham số các mã:

| Mã | N | K | R | Z | E | D Fully | D Partly | D Serial (cận dưới) |
|---|---|---|---|---|---|---|---|---|
| 648_12 | 648 | 324 | 0.50 | 27 | 2376 | 72 | 1080 | 85536 |
| 1296_12 | 1296 | 648 | 0.50 | 54 | 4644 | 72 | 2052 | 167184 |
| 648_34 | 648 | 486 | 0.75 | 27 | 2376 | 72 | 1080 | 85536 |

## 2. Số liệu đo và thông lượng (f = 75 MHz)

Chu kỳ D và T đo trong mô phỏng (core_monitor, 20 frame nhiễu, 0 bit lỗi, bit-exact với mô hình). f = 75 MHz là clock lõi của hệ thống PYNQ-Z2 (config.yaml), dùng chung cho mọi kiến trúc như một mức quy đổi cùng tần số (iso-frequency) để so sánh kiến trúc; chỉ Partly-parallel W = 1 đã build và đạt timing ở 75 MHz trong hệ thống, các cấu hình khác chưa được xác nhận chạy ở tần số này. Thông lượng là của lõi + wrapper, không gồm thời gian PS ghi dữ liệu qua AXI-Lite. Partly-parallel và Serial với W > 1 chỉ dùng để đo chu kỳ (không đại diện tài nguyên thật). Fully-parallel không vừa chip của PYNQ-Z2 (xc7z020): số của nó ở đây là so sánh cùng clock, không phải đo trên board.

| Kiến trúc | Mã | W | D đo | T đo | T mô hình | Tăng tốc S(W) | Θc (Mb/s) | Θi (Mb/s) | L (µs) |
|---|---|---|---|---|---|---|---|---|---|
| Fully-parallel | 648_12 | 1 | 72 | 651 | 651 | 1.00× | 74.654 | 37.327 | 8.68 |
| Fully-parallel | 648_12 | 2 | 72 | 327 | 327 | 1.99× | 148.624 | 74.312 | 4.36 |
| Fully-parallel | 648_12 | 3 | 72 | 219 | 219 | 2.97× | 221.918 | 110.959 | 2.92 |
| Fully-parallel | 648_12 | 6 | 72 | 111 | 111 | 5.86× | 437.838 | 218.919 | 1.48 |
| Fully-parallel | 648_12 | 9 | 72 | 75 | 75 | 8.68× | 648.000 | 324.000 | 1.00 |
| Fully-parallel | 648_12 | 12 | 72 | 74 | 74 | 8.80× | 656.757 | 328.378 | 0.99 |
| Fully-parallel | 648_12 | 24 | 72 | 74 | 74 | 8.80× | 656.757 | 328.378 | 0.99 |
| Fully-parallel | 1296_12 | 1 | 72 | 1299 | 1299 | 1.00× | 74.827 | 37.413 | 17.32 |
| Fully-parallel | 1296_12 | 2 | 72 | 651 | 651 | 2.00× | 149.309 | 74.654 | 8.68 |
| Fully-parallel | 1296_12 | 3 | 72 | 435 | 435 | 2.99× | 223.448 | 111.724 | 5.80 |
| Fully-parallel | 1296_12 | 6 | 72 | 219 | 219 | 5.93× | 443.836 | 221.918 | 2.92 |
| Fully-parallel | 1296_12 | 9 | 72 | 147 | 147 | 8.84× | 661.224 | 330.612 | 1.96 |
| Fully-parallel | 1296_12 | 12 | 72 | 111 | 111 | 11.70× | 875.676 | 437.838 | 1.48 |
| Fully-parallel | 1296_12 | 18 | 72 | 75 | 75 | 17.32× | 1296.000 | 648.000 | 1.00 |
| Fully-parallel | 1296_12 | 24 | 72 | 74 | 74 | 17.55× | 1313.514 | 656.757 | 0.99 |
| Fully-parallel | 648_34 | 1 | 72 | 651 | 651 | 1.00× | 74.654 | 55.991 | 8.68 |
| Fully-parallel | 648_34 | 2 | 72 | 327 | 327 | 1.99× | 148.624 | 111.468 | 4.36 |
| Fully-parallel | 648_34 | 3 | 72 | 219 | 219 | 2.97× | 221.918 | 166.438 | 2.92 |
| Fully-parallel | 648_34 | 6 | 72 | 111 | 111 | 5.86× | 437.838 | 328.378 | 1.48 |
| Fully-parallel | 648_34 | 9 | 72 | 75 | 75 | 8.68× | 648.000 | 486.000 | 1.00 |
| Fully-parallel | 648_34 | 12 | 72 | 74 | 74 | 8.80× | 656.757 | 492.568 | 0.99 |
| Fully-parallel | 648_34 | 24 | 72 | 74 | 74 | 8.80× | 656.757 | 492.568 | 0.99 |
| Partly-parallel | 648_12 | 1 | 1080 | 1082 | 1082 | 1.00× | 44.917 | 22.458 | 14.43 |
| Partly-parallel | 648_12 | 2 | 1080 | 1082 | 1082 | 1.00× | 44.917 | 22.458 | 14.43 |
| Partly-parallel | 648_12 | 3 | 1080 | 1082 | 1082 | 1.00× | 44.917 | 22.458 | 14.43 |
| Partly-parallel | 648_12 | 6 | 1080 | 1082 | 1082 | 1.00× | 44.917 | 22.458 | 14.43 |
| Partly-parallel | 648_12 | 9 | 1080 | 1082 | 1082 | 1.00× | 44.917 | 22.458 | 14.43 |
| Partly-parallel | 648_12 | 12 | 1080 | 1082 | 1082 | 1.00× | 44.917 | 22.458 | 14.43 |
| Partly-parallel | 648_12 | 24 | 1080 | 1082 | 1082 | 1.00× | 44.917 | 22.458 | 14.43 |
| Partly-parallel | 1296_12 | 1 | 2052 | 2054 | 2054 | 1.00× | 47.322 | 23.661 | 27.39 |
| Partly-parallel | 648_34 | 1 | 1080 | 1082 | 1082 | 1.00× | 44.917 | 33.688 | 14.43 |
| Serial | 648_12 | 1 | 86346 | 86348 | ≥ 85538 | 1.00× | 0.563 | 0.281 | 1151.31 |
| Serial | 648_12 | 2 | 86346 | 86348 | ≥ 85538 | 1.00× | 0.563 | 0.281 | 1151.31 |
| Serial | 648_12 | 3 | 86346 | 86348 | ≥ 85538 | 1.00× | 0.563 | 0.281 | 1151.31 |
| Serial | 648_12 | 6 | 86346 | 86348 | ≥ 85538 | 1.00× | 0.563 | 0.281 | 1151.31 |
| Serial | 648_12 | 9 | 86346 | 86348 | ≥ 85538 | 1.00× | 0.563 | 0.281 | 1151.31 |
| Serial | 648_12 | 12 | 86346 | 86348 | ≥ 85538 | 1.00× | 0.563 | 0.281 | 1151.31 |
| Serial | 648_12 | 24 | 86346 | 86348 | ≥ 85538 | 1.00× | 0.563 | 0.281 | 1151.31 |
| Serial | 1296_12 | 1 | 167940 | 167942 | ≥ 167186 | 1.00× | 0.579 | 0.289 | 2239.23 |
| Serial | 648_34 | 1 | 86184 | 86186 | ≥ 85538 | 1.00× | 0.564 | 0.423 | 1149.15 |

## 3. Hiệu quả phần cứng, mã 648 (LUT và Fmax từ báo cáo Vivado trong outfeed)

LUT và Fmax lấy từ báo cáo place & route out-of-context (chỉ lõi, không wrapper). Fmax = chu kỳ ngắn nhất đạt timing sau place & route; '≥' = mọi lần thử đều đạt, Fmax thật có thể cao hơn (Fully W = 6: đường tới hạn là một net fanout lớn chưa được nhân bản ở ràng buộc 20 ns). Các kiến trúc được đặt trên chip khác nhau vì Fully-parallel không vừa xc7z020; xc7z045/xc7z100 có fabric nhanh hơn xc7z020, nên cột Θi @ Fmax không phải so sánh cùng chip. 'RTL cũ' = báo cáo chạy trước lần sửa cổng nạp (Partly/Serial) và wrapper 75 MHz; với W = 1 logic tương đương (output mô phỏng giống từng bit) nhưng chưa synth lại.

| Cấu hình | Chip (place & route) | LUT | Fmax (MHz) | T | Θi @ 75 MHz (Mb/s) | Θi @ Fmax (Mb/s) | Mb/s / kLUT @ 75 MHz | RTL |
|---|---|---|---|---|---|---|---|---|
| Serial, W = 1 | xc7z020clg400-1 | 965 | 89.3 | 86348 | 0.281 | 0.335 | 0.292 | cũ |
| Partly-parallel, W = 1 | xc7z020clg400-1 | 7977 | ≥ 85.5 | 1082 | 22.458 | ≥ 25.603 | 2.815 | cũ |
| Fully-parallel, W = 1 | xc7z045ffv900-1 | 129876 | ≥ 100 | 651 | 37.327 | ≥ 49.770 | 0.287 | cũ |
| Fully-parallel, W = 6 | xc7z100ffg900-1 | 215757 | ≥ 50 | 111 | 218.919 | ≥ 145.946 | 1.015 | hiện tại |
