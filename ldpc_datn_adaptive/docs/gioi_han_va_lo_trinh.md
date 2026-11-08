# Giới hạn phần cứng dự kiến và lộ trình

## 1. Giới hạn phần cứng đã tổng hợp (`code/configs/hw_limits.yaml`)

| Hạng mục | Giá trị | Căn cứ |
|---|---|---|
| FPGA | xc7z020clg400-1 (PYNQ-Z2): 53 200 LUT, 106 400 FF | báo cáo `report_utilization` |
| Clock lõi | 30 MHz (đã đạt OOC, WNS +12,6 ns; Fmax ước tính ~48 MHz) | `outfeed/reports/latest_synth.json` |
| P_phys / C_phys | 24 VN unit / 12 CN unit | lưới QC 12×24: ánh xạ theo cột khối không dùng được quá 24 VN unit; ngân sách 36 không cần |
| P_act / C_act | {1,2,3,4,6,8,12,24} / {1,2,3,4,6,12} | vùng định tuyến sinh khi tổng hợp |
| VN unit | 12 khe (bậc ≤ 12) | 802.11n 648 có bậc 12; 1296 có bậc 11 |
| CN unit | 10 khe, ≤ 8 đầu vào khác 0 | tổng φ 7 bit của da2 |
| Bộ nhớ | 109 bank 64×6, Z ∈ {27, 54}, N ≤ 1296 | hợp các vị trí khối của 648 và 1296 |
| Tài nguyên lõi (OOC, sau route) | 21 973 LUT (41,3%), 9 877 FF, 3 207 LUTRAM | `run.py synth`, chưa gồm wrapper AXI/PS |

Dung lượng bộ nhớ từng mã cần: chạy `script/check_config.py`.

Số đo nền từ Đồ án 2 (đo ngày 2026-11-08; nguồn chi tiết:
`outfeed/reports/comparison.md` của `ldpc_da2_configurable` và
`ldpc_da2_qc_wifi`). Cùng FPGA, cùng clock lõi 30 MHz, cùng thuật toán.
LUT/FF là của **lõi**; công suất là ước tính `report_power`, chưa đo trên board.

| Mã / kiến trúc | Chu kỳ/frame | LUT lõi | FF lõi | Trạng thái |
|---|---|---|---|---|
| 1152 Serial | 124 848 | 508 | 398 | timing đạt, test đạt |
| 1152 Partly-Parallel (da2, 36 PE) | 1 405 | 25 370 | 26 348 | bản sao đã sửa wrapper/`last_f_id`: WNS +0,107 ns, regression/noisy PASS (da2 gốc: WNS −0,579, FAIL) |
| 1152 Fully-Parallel | 72 | 179 113 (synth) | 120 981 | không vừa xc7z020 (338% LUT, 116% FF) |
| 648 Serial | 86 346 | 932 | 577 | timing đạt, test đạt |
| 648 Partly-Parallel QC (24 PE) | 1 080 | 8 293 | 4 485 | timing đạt, test đạt |
| 648 Fully-Parallel | 72 | 126 185 (synth) | 62 225 | không vừa xc7z020 (239% LUT) |

Hệ quả cho khảo sát: một cụm 36 PE theo kiểu da2 đã chiếm khoảng một nửa số LUT
của xc7z020, nên P_phys = 36 cần được đánh giá lại về tài nguyên, không mặc
định giữ nguyên.

## 2. Lộ trình

| Giai đoạn | Nội dung | Trạng thái (2026-11-08) |
|---|---|---|
| 0 | Số liệu nền Đồ án 2 | xong (bảng trên) |
| 1 | Mapper/lập lịch, kiểm tra xung đột, ước tính chu kỳ | xong cho QC 12×24 (`script/mapper.py`) |
| 2 | Mô hình chu kỳ hiệu chỉnh bằng RTL | trùng 100% ở 14 tổ hợp đã chạy |
| 3 | RTL cụm dùng chung, P_phys cố định, cấu hình bằng bảng | xong: `adaptive_core.sv`, synth/impl OOC 41% LUT, WNS +12,6 ns @30 MHz |
| 4 | Nhiều mã trên cùng phần cứng, chọn P_act lúc chạy | xong cho 648 và 1296 (plan `mixed`); 1152 chưa (không QC) |
| 5 | Bộ chọn P_act/C_act theo latency/throughput | xong (`run.py select`) |
| 6 | Wrapper AXI, bitstream PYNQ-Z2, đo trên board | chưa |
| 7 | Mã không QC (1152): mạng hoán vị theo chu kỳ hoặc bảng địa chỉ tường minh | chưa |

Mỗi giai đoạn dùng mô hình bit-accurate làm tham chiếu chức năng. Không nới
tiêu chí kiểm tra để đạt mốc.

## 3. Cần đối chiếu trước khi nói về tính mới

Chưa tra cứu tài liệu, nên chưa có kết luận nào về tính mới. Các hướng cần
khảo sát và so sánh:

- decoder QC-LDPC đa chế độ / đa tốc độ cho 802.11n, 802.16e, 5G NR (dùng
  chung PE, bộ dịch vòng cấu hình được);
- decoder bán song song với số PE hoạt động thay đổi lúc chạy và đánh đổi
  throughput–năng lượng;
- phương pháp ánh xạ/lập lịch tránh xung đột bộ nhớ (memory conflict) cho
  decoder bán song song, layered và flooding;
- kiến trúc kiểu Zhang–Parhi (mã (3,6) gắn với cấu trúc decoder, nền của da2)
  và khả năng tổng quát hóa của nó.

Kết quả khảo sát sẽ quyết định phần nào của đồ án là đóng góp, phần nào là
hiện thực lại.
