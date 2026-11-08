# ldpc_da2_qc_wifi — QC-LDPC IEEE 802.11n (648,324), rate 1/2

Decoder cho mã Wi-Fi với cùng thuật toán và số học của `ldpc_da2`, tổ chức để
so sánh ba kiến trúc như `ldpc_da2_configurable`. Dự án chạy độc lập; kết quả
nằm trong `outfeed/`. Bản (1296,648) mới chuẩn bị cấu trúc, chưa có RTL/test.

## 1. Ma trận H: nguồn, quy ước, cách tạo

- Ma trận cơ sở: `code/data/base_matrices/648_12.txt` (12×24, Z = 27) và
  `1296_12.txt` (12×24, Z = 54). Hai file chép nguyên văn từ
  <https://github.com/simgunz/802.11n-ldpc>, commit
  `615b59463386574bf266228ab70f0dddbc8ce227`, thư mục `protoH/`.
  Nguồn chuẩn gốc là các bảng ma trận LDPC HT trong IEEE 802.11 (Annex F;
  tài liệu trích dẫn khi tìm kiếm ghi Table F-2 cho n = 1296). Văn bản chuẩn
  không có trong workspace và chưa được đối chiếu trực tiếp, nên dùng cách
  kiểm chứng dưới đây.
- Đối chiếu độc lập: `648_34.txt` lấy từ cùng commit trùng từng số với ma trận
  802.11 rate 3/4 in trong tài liệu MathWorks `ldpcQuasiCyclicMatrix`.
- Kiểm tra cấu trúc (`run.py check`): rank 324 (k = 324), bậc VN {2, 3, 12},
  bậc CN {7, 8}, 2376 cạnh, 88 khối khác 0; phần parity có cột đầu với dịch
  1, 0, 1 và 11 cột dual-diagonal; mọi codeword sinh ra đều có H·c = 0.
- Quy ước (giống `buildH.m`: `circshift(eye(Z),[0 k])`): giá trị k ≥ 0 là ma
  trận đơn vị dịch phải k cột, giá trị âm là khối 0:
  `H[r*Z + i, c*Z + (i + k) mod Z] = 1`. Bit codeword n = cột n của H = mẫu
  đầu vào thứ n; bit 0..323 là thông tin (mã hệ thống).
- Mã hóa (`gen_data.py`): c = [s, p], p = Hp⁻¹·Hs·s trên GF(2). Kênh và lượng
  tử giống hệt da2 (BPSK, AWGN `RandomState(seed)`, LLR = 2y/σ², 5 bit). Ảnh
  `eye.png` → 1245 frame + 2 frame xả. Expected là codeword Wi-Fi sạch; không
  dùng expected của mã 1152.

## 2. Tái sử dụng và thay đổi so với `ldpc_da2`

| Khối da2 | Ở đây | Ghi chú |
|---|---|---|
| `LUT.v` (φ) | dùng nguyên | `code/rtl/da2_units/Utilities/LUT.v` |
| `VNU.v` | thay bằng `VNU_G` | bậc là tham số (2..12); bộ cộng rộng theo bậc (bậc 12 cần 9 bit); cùng 2 tầng, cùng đầu ra {hd, dấu, φ} |
| `CNU.v` | thay bằng `CNU_G` | bậc 7/8; cùng 1 tầng thanh ghi, tổng φ 7 bit, dấu XOR, parity |
| `S_to_T`, `T_to_S`, ripple adder | gộp vào `VNU_G`/`CNU_G` | cùng phép toán (kiểm bằng test `units`) |
| `PE_block` + `ADDRESS_GENERATOR` | ý tưởng giữ, viết lại trong `ldpc_core_qc_pp.sv` | PE = cột khối (24 PE × 27 VN); INT/DEC RAM hai bank; một RAM message cho mỗi khối khác 0; bộ sinh địa chỉ bắt đầu từ giá trị dịch (≈ `COUNT_FROM`), đếm mod 27 |
| `PI_1/PI_2/PI_3` | bỏ | ma trận QC: CN i của hàng r đọc địa chỉ (i + dịch) của mỗi khối → nối cứng theo ma trận cơ sở |
| `clk`/`clk_df` | bỏ | một clock 30 MHz |
| Lịch, 18 vòng, đóng băng quyết định, trễ 2 transaction, AXI COD1 | giữ nguyên | wrapper và test giống `ldpc_da2_configurable`, tham số N = 648 (18 chunk) |

`code/tests/tb_units_equiv.sv` so `VNU_G(3)` với `VNU.v` và `CNU_G(6)` với
`CNU.v` từng chu kỳ trên 200 000 vector ngẫu nhiên. Đây là bằng chứng số học
không đổi.

## 3. Ba kiến trúc

| | Serial | Partly-Parallel (QC) | Fully-Parallel |
|---|---|---|---|
| RTL lõi | `serial/ldpc_core_serial.sv` (chung với configurable) | `partly_parallel/ldpc_core_qc_pp.sv` | `fully_parallel/ldpc_core_fp.sv` (chung) |
| PE | 1 VN unit (bậc 12) + 1 CN unit (bậc 8) | 24 PE (1 VN unit/cột khối) + 12 CN unit (1/hàng khối) | 648 VN unit + 324 CN unit |
| Song song | 1 nút; 1 đọc + 1 ghi message/clock | 24 VN hoặc 12 CN mỗi clock, 27 địa chỉ/pha | mọi nút |
| Chu kỳ/vòng | ≈ 2×2376 + đường ống | 60 (27+3, 27+2, 1) | 4 |

Bảng sinh từ H (`gen_rtl.py`) nằm trong `code/rtl/generated/ldpc_code_pkg.sv`
(gồm cả bảng khối QC) và `serial_rom.v`; RTL dùng `import ldpc_code_pkg::*`.

Bậc thực tế mỗi VN/CN unit trong Serial được đệm 0. Giá trị 0 là trung tính:
cộng 0, φ = 0, dấu 0, parity 0.

## 4. Lệnh (chạy trong `ldpc_da2_qc_wifi`)

```powershell
python script/run.py check
python script/run.py data
python script/run.py sim --test units
python script/run.py sim --arch partly_parallel --test regression
python script/run.py sim --arch serial --test noisy --waves core --gui
python script/run.py build --arch partly_parallel
python script/run.py package --arch partly_parallel
python script/run.py report
python script/gen_data.py --code 1296_12 --snr 3 --out outfeed/data/wifi1296_snr3   # chỉ dữ liệu
```

Test: `units`, `smoke`, `regression`, `noisy` (SNR 3 dB, 20 codeword, so cả
codeword sạch và mô hình bit-accurate), `full` (1245 codeword), `core` (lõi,
không AXI). Sóng, trình mô phỏng (`--sim`), điều kiện đóng gói giống
`ldpc_da2_configurable/script/README.md`.

## 5. Mở rộng sang (1296,648)

Đã có: ma trận cơ sở, H và kiểm tra cấu trúc (`ldpc_common.CODES`), tạo dữ
liệu `--code 1296_12`. Chưa làm: chọn code mặc định khi sinh RTL (`gen_rtl.py`
dùng `DEFAULT_CODE`), wrapper/test với N = 1296 (36 chunk), mô phỏng và build.
Bậc VN tối đa 11 và bậc CN 7/8 nằm trong phạm vi của `VNU_G`/`CNU_G`.
