# Ý tưởng bài báo: so sánh 3 kiến trúc giải mã QC-LDPC 802.11n

**Mô hình → Kiểm chứng trên 3 mã → Nút cổ chai → Chọn kiến trúc theo ứng dụng**

Tóm tắt một câu: thay vì đo một lần trên một mã, ta viết **công thức** cho từng kiến trúc, **kiểm chứng** trên nhiều mã, dùng nó để **giải thích** vì sao mỗi kiến trúc nhanh hay chậm, rồi **chọn kiến trúc** cho từng ứng dụng.

---

## Vấn đề của bài hiện tại

Bài chỉ có 3 điểm đo: ba kiến trúc trên **một mã** (648, R = 1/2). Phản biện sẽ hỏi:

- Đổi sang mã dài hơn hoặc tốc độ mã khác thì kết luận còn đúng không?
- Vì sao ra các con số đó?
- Mỗi kiến trúc dùng cho ứng dụng nào?

---

## Bước 1: Mô hình

Đọc FSM trong RTL và viết công thức số chu kỳ theo tham số của mã (18 vòng lặp):

| Kiến trúc | Chu kỳ / vòng | Phụ thuộc vào |
|---|---|---|
| Serial | ≈ 2 × E (+ vài chu kỳ phụ) | Số cạnh E: mỗi chu kỳ xử lý 1 cạnh |
| Partly-parallel | 2 × Z + 6 | Kích thước khối Z |
| Fully-parallel | 4 | Không phụ thuộc mã |
| Cả lần giải mã | max(giải mã + 2, N + 3) | Đường nạp 1 mẫu/chu kỳ |

Tài nguyên chỉ mô tả ở mức **xu hướng**:
- serial tăng theo E (bộ nhớ);
- partly-parallel tăng theo Z và số khối;
- fully-parallel tăng theo N và E.

---

## Bước 2: Kiểm chứng trên 3 mã

| Mã | Thay đổi | Serial | Partly | Fully |
|---|---|---|---|---|
| 648, R = 1/2 | (gốc) | 86 348 | 1 082 | 651 |
| 1296, R = 1/2 | Z: 27 → 54, N gấp đôi | 167 942 | 2 054 | 1 299 |
| 648, R = 3/4 | Đổi ma trận H, giữ N và Z | 86 186 | 1 082 | 651 |

- **Mã 648:** công thức khớp cả 6 số đo. Đây chỉ là **kiểm tra nhất quán**, vì công thức suy ra từ chính RTL đó.
- **Mã 1296 và 648 R = 3/4:** **dự đoán trước**, sau đó mới chạy Vivado để đo. Đây là kiểm chứng thật.
- **Báo cáo** kết quả dạng: dự đoán – đo được – sai số %. Nếu lệch thì phân tích vì sao.
- **Đo thêm** cho mỗi mã: LUT, FF, BRAM, **Fmax** và công suất.
  - Fully-parallel không vừa PYNQ-Z2 nên chỉ lấy số synthesis.

---

## Bước 3: Nút cổ chai

Mô hình chỉ ra mỗi kiến trúc bị kẹt ở đâu:

| Kiến trúc | Bị kẹt ở đâu | Cải tiến nhẹ | Ước tính (mã 648) |
|---|---|---|---|
| Serial | RAM 1 cổng | RAM 2 cổng | 86 346 → ~43 800 chu kỳ |
| Partly-parallel | VNU/CNU chỉ bận ~45% | Xen kẽ 2 khung | 1 082 → ~541 chu kỳ |
| Fully-parallel | Giải mã 72 chu kỳ, nạp dữ liệu 651 | Nạp 6 mẫu/lần | 651 → ~111 chu kỳ |

**Phát hiện chính:** với đường nạp 1 mẫu/chu kỳ, không kiến trúc nào vượt quá ~1 bit/chu kỳ.
Fully-parallel tốn gấp ~14 lần LUT nhưng chỉ nhanh hơn partly-parallel ~1,7 lần.

Nếu kịp: làm cải tiến **nạp 6 mẫu/lần** và đo thật để chứng minh.

---

## Bước 4: Chọn kiến trúc theo ứng dụng (kết luận)

Từ bước 2 và 3 ta có **bit/chu kỳ** của từng kiến trúc (serial ≈ 0,0075; partly ≈ 0,6; fully ≈ 1). Từ đó:

- Thông lượng = bit/chu kỳ × Fmax
- Độ trễ = số chu kỳ / Fmax
- Tần số cần cho ứng dụng T Mb/s = T / (bit/chu kỳ)

| Yêu cầu | Serial | Partly-parallel | Fully-parallel |
|---|---|---|---|
| ≤ 1 Mb/s | ✓ nhỏ nhất | ✓ | ✗ không vừa chip |
| ~10–20 Mb/s | ✗ | ✓ | ✗ không vừa chip |
| ~100 Mb/s | ✗ | ? (cần ~167 MHz) | ✗ trên PYNQ-Z2 |
| 600 Mb/s [Roth 2010] | ✗ | ✗ | chỉ khi nạp rộng + chip lớn |

Kết luận cho từng kiến trúc:
- **Serial:** tốc độ thấp, tài nguyên ít nhất.
- **Partly-parallel:** cân bằng nhất trên FPGA giá rẻ.
- **Fully-parallel:** chỉ đáng dùng khi có chip lớn và đường nạp rộng.

Lưu ý:
- Mỗi mức yêu cầu phải có nguồn.
- Quy đổi bit codeword sang bit thông tin bằng cách nhân với tốc độ mã R.
- Ô "?" được điền sau khi có Fmax.

---

## Nếu không được thì sao

| Trường hợp | Đường lui |
|---|---|
| Đo không khớp dự đoán | Phân tích vì sao lệch, báo sai số trung thực |
| Mã mới chạy lỗi | Dùng mã chạy được (648 + 1296 là đủ thấy quy luật) |
| Không có Fmax | Dùng 30 MHz làm mức chắc chắn đạt + bảng tần số cần thiết |
| Bị chê mô hình hiển nhiên | Đẩy bước 3 (nút cổ chai + cải tiến nạp rộng có số đo) lên làm đóng góp chính |

## Thứ tự làm

1. Chạy lại test mã 648 sau khi sửa `cnu_g.sv`.
2. Chạy mã 1296 (serial, partly).
3. Lấy Fmax bằng cách siết ràng buộc clock dần.
4. Chạy mã 648 R = 3/4.
5. Nếu kịp: cải tiến nạp 6 mẫu.
6. Viết bài.
