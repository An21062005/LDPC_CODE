# Ý tưởng bài báo v3: so sánh 3 kiến trúc giải mã QC-LDPC 802.11n

**Mô hình → Kiểm chứng trên 3 mã → Nút cổ chai (có cải tiến đo thật) → Chọn kiến trúc theo ứng dụng**

Bản v3 cập nhật v2 theo số đo trong `ldpc_qc_wifi_arch_study/outfeed/` (2026-11-19/20). Mọi số đều từ lần chạy mới trong thư mục này; ghi rõ số nào là ước tính sau synth, số nào sau place & route.

---

## Bước 1: Mô hình (đọc từ RTL, 18 vòng lặp)

| Kiến trúc | Chu kỳ giải mã | Ghi chú |
|---|---|---|
| Serial | ≥ 18 × 2E, thực tế +0,5–1 % | 1 cạnh/chu kỳ mỗi pha; phần dư do stall FIFO, phụ thuộc phân bố bậc nút |
| Partly-parallel | 18 × (2Z + 6) | pha VN Z+3, pha CN Z+2, EVAL 1 |
| Fully-parallel | 18 × 4 = 72 | không phụ thuộc mã |
| **Cả transaction** | **max(giải mã + 2, N/W + 3)** | W = số mẫu nạp/đọc mỗi chu kỳ (bản gốc W = 1) |

Tài nguyên (đo, lõi OOC trên xc7z020): serial tăng theo E (BRAM), LUT gần như không đổi; partly tăng theo Z chủ yếu ở LUTRAM (số PE giữ 24 + 12); fully tăng theo N và E.

---

## Bước 2: Kiểm chứng trên 3 mã (chu kỳ / transaction, mô phỏng XSim, 20 codeword nhiễu, 0 bit lỗi, khớp bit-exact với mô hình)

| Mã | Thay đổi | Serial (cận dưới → đo) | Partly (dự đoán → đo) | Fully (dự đoán → đo) |
|---|---|---|---|---|
| 648, R = 1/2 | gốc | 85 538 → 86 348 (+0,95 %) | 1082 → 1082 | 651 → 651 |
| 1296, R = 1/2 | Z 27 → 54, N gấp đôi | 167 186 → 167 942 (+0,45 %) | 2054 → 2054 | 1299 → 1299 |
| 648, R = 3/4 | H khác (bậc CN 14–15), giữ N, Z, E | 85 538 → 86 186 (+0,76 %) | 1082 → 1082 | 651 → 651 |

- Partly và fully: công thức đúng **chính xác từng chu kỳ** trên cả 3 mã.
- Serial: chỉ cho cận dưới; sai số < 1 %. Ghi trung thực: số serial của 1296 và R = 3/4 đã có từ trước (không phải dự đoán mù).
- Mã R = 3/4 cần nới bộ cộng CNU từ 7 lên 8 bit (tổng tới 210); LUT.v trả 0 với mọi chỉ số ≥ 64 nên kết quả mã R = 1/2 **không đổi từng bit** (đã chạy lại so với bản gốc).
- Dự đoán cho partly/fully/W = 6 ghi trong `outfeed/predictions_before_sim.md` **trước** khi mô phỏng.

### Tài nguyên và Fmax lõi (OOC, xc7z020, quét chu kỳ 0,1 ns, chu kỳ ngắn nhất đạt timing)

| Kiến trúc | Mã | LUT | FF | BRAM | LUTRAM | Fmax (MHz) |
|---|---|---|---|---|---|---|
| Serial | 648 R1/2 | 965 | 577 | 6,5 | 58 | 89,3 |
| Serial | 1296 R1/2 | 862 | 567 | 12 | 54 | 90,9 |
| Serial | 648 R3/4 | 960 | 571 | 6,5 | 62 | 94,3 |
| Partly | 648 R1/2 | 7 977 | 4 477 | 0 | 1 285 | ≥ 85,5 |
| Partly | 1296 R1/2 | 8 992 | 4 329 | 0 | 2 549 | ≥ 80,0 |
| Partly | 648 R3/4 | 8 107 | 4 466 | 0 | 1 285 | 77,5 |
| Fully | 648 R1/2 | 130 294 (245 %) | 62 221 | 0 | 0 | ~90,8 (ước tính sau synth, không vừa chip) |
| Fully | 1296 R1/2 | 253 894 (477 %) | 122 161 (115 %) | 0 | 0 | ~85,5 (ước tính sau synth, không vừa chip) |
| Fully | 648 R3/4 | 138 609 (261 %) | 61 897 | 0 | 0 | ~93,2 (ước tính sau synth, không vừa chip) |
| Fully W = 6 | 648 R1/2 | 216 376 (407 %) | 62 226 | 0 | 0 | ~90,8 (ước tính sau synth, ràng buộc 20 ns) |
| **Fully trên xc7z045 (impl)** | 648 R1/2 | **129 876 (59,4 %)** | 62 349 (14,3 %) | 0 | 0 | **100,0** (đạt tại 10 ns, WNS +0,088, WHS +0,091) |

- Fully trên xc7z020 chỉ chạy được synth (không vừa chip); Fmax là ước tính 1/(P − WNS) sau synth, chưa qua place & route.
- Fully 648 R1/2 trên xc7z045ffv900-1 đã place & route thành công: đạt 100 MHz, LUT gần đúng như ước tính synth (129 876 so với 130 294). Fmax impl (100) cao hơn ước tính synth trên xc7z020 (90,8) vì khác chip. Công suất vectorless 3,65 W (động 3,43 W).
- Fully tăng ~2× khi N gấp đôi (1296: LUT 1,95×, FF 1,96×), đúng mô hình "tăng theo N và E". So với partly cùng mã: 16,3× (648 R1/2), 17,1× (648 R3/4), 28,2× (1296) LUT.
- Fully W = 6 synth ở 10 ns bị kẹt > 3 giờ ở bước tối ưu timing của Vivado (bản W = 1 chỉ mất 24 s), nên synth lại ở 20 ns (WNS +8,99 → ước tính 90,8 MHz). Số Fmax này kém tin cậy hơn các dòng khác.
- Partly R = 3/4 có Fmax thấp nhất (77,5 MHz) vì CNU cộng 15 đầu vào: đổi mã không đổi số chu kỳ nhưng đổi Fmax.
- "≥": hết số lần thử mà vẫn đạt timing. Kết quả place & route có dao động ~0,2 ns giữa các lần chạy.
- Công suất (vectorless, lõi): serial ~0,14 W, partly ~0,24–0,27 W, phần tĩnh ~0,10 W chiếm đa số → chỉ dùng làm xu hướng. Fully (xc7z045) 3,65 W.

---

## Bước 3: Nút cổ chai (sửa so với v2)

| Kiến trúc | Bị kẹt ở đâu | Cải tiến | Kết quả |
|---|---|---|---|
| Serial | 1 cạnh/chu kỳ: RAM tin nhắn đã đọc 1 + ghi 1 mỗi chu kỳ (dùng hết 2 cổng BRAM) | chia bank RAM, 2 cạnh/chu kỳ, 2 VNU/CNU | ~43 k chu kỳ (**ước tính**, không phải cải tiến nhẹ, chưa làm) |
| Partly | VNU/CNU chỉ bận 27/60 = 45 % | xen kẽ 2 khung | 1082 → **651**: bị chặn bởi đường nạp; chỉ xuống ~541 khi nạp ≥ 2 mẫu/chu kỳ (**ước tính**) |
| Fully | giải mã 72, nạp 651 | **nạp 6 mẫu + đọc 6 bit/chu kỳ (đã làm, đo thật)** | 648: 651 → **111**; 1296: 1299 → **219** (đúng dự đoán) |

**Phát hiện chính (có số đo):**
- Với đường nạp 1 mẫu/chu kỳ, transaction ≥ N + 3 nên không kiến trúc nào vượt ~1 bit/chu kỳ. Fully tốn **16,3×** LUT của partly nhưng chỉ nhanh **1,66×**.
- Nới đường nạp/đọc lên 6 mẫu/chu kỳ: fully đạt **5,84 bit/chu kỳ** (648) và 5,92 (1296), nhanh **5,9×** fully gốc và **9,7×** partly. Chi phí wrapper: thêm 5 BRAM18 (6 bank bộ đệm vào). Chi phí lõi (synth): **+86 082 LUT (+66 %)** so với fully W = 1 (216 376 so với 130 294), FF gần như không đổi. Mức tăng lớn này nhiều khả năng do cách viết RTL hiện tại (chỉ số động `load_addr*6 + w` khi ghi/đọc), chưa tối ưu; chưa phân tích chi tiết nên ghi là chi phí của bản hiện tại, không phải chi phí tối thiểu.
- Với W = 6, giới hạn vẫn là nạp (108 + 3 > 72 + 2). Từ W ≥ 10 thì giải mã (72 chu kỳ) mới thành giới hạn.

---

## Bước 4: Chọn kiến trúc theo ứng dụng

Thông lượng thông tin = (K / chu kỳ transaction) × Fmax; độ trễ = chu kỳ / Fmax. Số dưới đây là **lõi tại Fmax OOC**; hệ thống trên board hiện chạy lõi ở 30 MHz (MMCM).

| Kiến trúc (mã 648 R1/2) | bit thông tin/chu kỳ | Mb/s thông tin @ Fmax | Độ trễ @ Fmax | Mb/s thông tin @ 30 MHz |
|---|---|---|---|---|
| Serial | 0,0038 | 0,34 | 967 µs | 0,11 |
| Partly | 0,30 | 25,6 | 12,7 µs | 9,0 |
| Fully (W = 1), xc7z045 | 0,50 | **49,8** (100 MHz, impl) | **6,5 µs** | 14,9 |
| Fully (W = 6) | 2,92 | ~265 (90,8 MHz, ước tính synth) | ~1,2 µs | 87,6 |

- Fully W = 6 chưa place & route: 216 k LUT chiếm ~99 % LUT của xc7z045 (218,6 k) nên khó vừa; trên xc7z100 (277 k LUT) chiếm ~78 % nhưng chưa chạy. Dòng W = 6 là **ước tính**.
- Mã 648 R3/4: serial 0,53, partly 34,8 Mb/s thông tin (R lớn hơn bù Fmax thấp hơn).

| Yêu cầu (thông tin) | Serial | Partly | Fully W = 1 | Fully W = 6 |
|---|---|---|---|---|
| ≤ 0,5 Mb/s | ✓ nhỏ nhất (~1 k LUT) | ✓ | ✗ không vừa xc7z020 | ✗ không vừa xc7z020 |
| ~10–25 Mb/s | ✗ | ✓ nếu nâng clock hệ thống lên ≥ 67–85 MHz (Fmax lõi 85,5; cần build lại hệ thống để xác nhận) | ✗ trên xc7z020 | ✗ trên xc7z020 |
| ~50 Mb/s | ✗ | ✗ (cần ~167 MHz) | ✓ trên xc7z045 (49,8 Mb/s @ 100 MHz, đo impl lõi; 130 k LUT) | ✓ (dư) |
| ~100 Mb/s | ✗ | ✗ (cần ~333 MHz) | ✗ (cần ~201 MHz) | ✓ ước tính: cần ~34 MHz, Fmax ước tính 90,8; cần chip ≥ xc7z100 hoặc tối ưu RTL nạp |
| 600 Mb/s [cần nguồn] | ✗ | ✗ | ✗ | ✗ với W = 6 (cần ~206 MHz) |

Kết luận:
- **Serial:** rẻ nhất, < 1 Mb/s.
- **Partly:** cân bằng nhất trên FPGA giá rẻ: ~25–35 Mb/s thông tin ở Fmax với ~8 k LUT.
- **Fully W = 1:** trên xc7z045 đạt 49,8 Mb/s (gấp 1,95× partly) nhưng tốn 16,3× LUT, vì đường nạp 1 mẫu/chu kỳ giới hạn.
- **Fully W = 6:** nhanh nhất (~265 Mb/s ước tính, 5,9× fully W = 1), nhưng bản RTL hiện tại tốn thêm 66 % LUT và cần chip lớn hơn xc7z045. Fully chỉ đáng dùng khi có chip lớn **và** đường nạp rộng.

---

## Khả năng sửa lỗi (mô hình Python, bit-exact với RTL cả 4 kiến trúc)

`ldpc_qc_wifi_arch_study/outfeed/ber_model_*/ber_fer.md` (ảnh eye.png, seed 42; 1245 / 623 / 830 frame). Mô hình khớp chính xác BER/FER đo bằng RTL của dự án gốc ở 1,0–3,0 dB.

| Mã | FER ≈ 1–2 % tại Eb/N0 | Error floor |
|---|---|---|
| 648 R1/2 | ~3,0–3,5 dB | FER ~ 1e-3 tới 6,5 dB |
| 1296 R1/2 | ~3,0–3,5 dB | FER ~ 1,6e-3 (1 frame / 623) |
| 648 R3/4 | ~3,7 dB (SNR gen_data 5,5 dB) | FER 1,2e-3 tại Eb/N0 4,7 dB |

- Error floor: frame lỗi chỉ sai 1–5 bit, **không bao giờ đạt syndrome 0** (lỗi phát hiện được), 67–90 % LLR bão hòa ở ±3,75. Nhiều khả năng do lượng tử thô (LLR 5 bit, phi 4 bit) kế thừa da2; không đổi thuật toán trong bài, nêu là giới hạn.
- Đo ở mức thống kê hạn chế (≤ 1245 frame): FER < ~1e-3 không phân giải được.

---

## Giới hạn cần ghi trong bài

- Fmax là của lõi OOC (cổng vào/ra không ràng buộc); hệ thống chưa build lại ở clock cao hơn 30 MHz.
- Fully trên xc7z020 và fully W = 6 chỉ có số sau synth (ước tính); chỉ fully W = 1 mã 648 R1/2 đã place & route (xc7z045). Chưa kiểm tra license để tạo bitstream cho xc7z045, và không nạp board.
- Chi phí W = 6 (+66 % LUT) là của RTL hiện tại, chưa tối ưu.
- Đường AXI-Lite (PS ghi từng mẫu) là nút cổ chai thật của cả hệ thống; chưa đo (cần board).
- Công suất là ước tính vectorless.
- Serial 2 cạnh/chu kỳ và partly xen kẽ khung chỉ là ước tính.
- Mức "600 Mb/s [Roth 2010]" và các mức ứng dụng khác cần nguồn trích dẫn.

## Thứ tự làm còn lại

1. ✓ Số fully-parallel (W = 1 cả 3 mã, W = 6 mã 648, impl xc7z045 cho 648 R1/2).
2. (Tùy chọn) tối ưu đường nạp W = 6 trong lõi rồi impl trên chip lớn (xc7z100) để có Fmax đo thật.
3. (Tùy chọn) build hệ thống partly ở clock cao hơn để xác nhận dòng 10–25 Mb/s.
4. Viết bài.
