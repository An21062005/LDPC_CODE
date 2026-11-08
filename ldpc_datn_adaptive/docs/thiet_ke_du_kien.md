# Thiết kế decoder thích nghi

Mục 2–4 đã hiện thực cho mã QC 12×24 (802.11n 648/1296); mục 5 là phần còn
dự kiến. Thuật toán và số học giữ như `ldpc_da2` (φ-LUT, LLR 5 bit, 18 vòng,
đóng băng quyết định).

## 1. Mô tả mã (`format: ldpc-code/1`)

| Trường | Ý nghĩa | Bắt buộc |
|---|---|---|
| `name` | tên cấu hình | có |
| `n`, `k` | độ dài codeword, số bit thông tin (k = n − rank H) | có |
| `structure.type` | `explicit` (H tường minh) hoặc `qc` | có |
| `structure.h_file` | H dạng `.npy` 0/1 (explicit) | explicit |
| `structure.z`, `base_matrix_file`, `shift` | kích thước khối, ma trận cơ sở (−1 = khối 0), quy ước dịch (`right_cyclic`: `H[r*Z+i, c*Z+(i+s) mod Z] = 1`) | qc |
| `structure.bit_order` | quan hệ bit codeword ↔ cột H ↔ mẫu đầu vào | có |
| `degrees.vn`, `degrees.cn`, `degrees.edges` | khai báo để kiểm chéo với H | có |
| `arithmetic.*` | `algorithm`, `llr_bits`, `message_bits`, `iterations`, `stop` | có |
| `schedule` | `flooding` (lịch duy nhất đã hiện thực) | có |

Ví dụ hợp lệ (đã qua `check_config.py`): `da2_1152_r12.yaml` (explicit,
(3,6), k = 580), `wifi_648_r12.yaml` (QC, Z = 27), `wifi_1296_r12.yaml` (QC,
Z = 54, chưa có decoder).

## 2. Cụm PE và bộ nhớ dùng chung (`code/rtl/adaptive/adaptive_core.sv`)

- **Vật lý (chốt khi tổng hợp, `code/configs/hw_limits.yaml`):** P_phys = 24
  VN unit (12 khe, một khe/hàng khối), C_phys = 12 CN unit (10 khe), 109 bank
  message 64×6 — một bank cho mỗi vị trí khối trong **hợp** các mã của phần
  cứng (648 có 88 khối, 1296 có 86, chung 65). Mỗi cột khối có RAM intrinsic
  và RAM quyết định hai bank (nạp frame sau khi giải frame trước, như da2).
  Ngân sách 36 PE không dùng hết: với ánh xạ theo cột khối, mã 12×24 không
  dùng được quá 24 VN unit.
- **Lúc chạy:** Z (27/54), bảng `valid`/`shift` từng vị trí, số bước VN/CN và
  bảng lịch (unit, bước) → cột/hàng, nạp qua cổng cấu hình (`cfg_*`) khi lõi
  rỗi; ghi lúc bận bị bỏ qua và bật `cfg_err`. Vị trí không thuộc mã hiện tại
  đọc ra 0 (trung tính cho cả VN và CN).
- **P_act / C_act:** VN unit p lần lượt xử lý các cột trong lịch của nó (mỗi
  bước Z chu kỳ); unit không có trong lịch đứng yên. Định tuyến là mux trên tập
  cột (hàng) ứng viên của từng unit, sinh khi tổng hợp từ tập P (C) cho phép
  {1,2,3,4,6,8,12,24} ({1,2,3,4,6,12}). Đây là ánh xạ + định tuyến + điều khiển
  thật, không phải chỉ tắt bớt PE: số chu kỳ thay đổi đúng theo lịch.
- **Bất biến số học:** CN unit 10 khe nhưng mapper từ chối mã có bậc hàng > 8,
  nên tổng φ 7 bit của da2 vẫn chính xác (`CNU_G` có tham số `NZ`).

## 3. Ánh xạ, lập lịch, xung đột (`script/mapper.py`)

- Chính sách: cột c → unit c mod P_act, bước c div P_act; hàng tương tự với
  C_act. Số bước = ⌈24/P⌉ (VN), ⌈12/C⌉ (CN). Thanh ghi số bước nạp vào lõi
  lấy từ chính lịch (bước lớn nhất + 1); (unit, bước) ngoài bảng phần cứng bị
  từ chối.
- Kiểm tra bằng phát lại từng chu kỳ với độ trễ RTL (VN ghi = đọc + 3, CN ghi
  = đọc + 2): mỗi cạnh của H đúng một lần mỗi pha và đúng bank/địa chỉ; ≤ 1
  đọc và ≤ 1 ghi mỗi bank mỗi chu kỳ; không ghi trước khi đọc; unit chỉ nhận
  cột/hàng trong vùng định tuyến. `mapper.py selftest` làm hỏng lịch theo bốn
  kiểu và yêu cầu cả bốn bị từ chối.
- Xung đột bank không xảy ra theo cấu trúc: mỗi bank thuộc một cột và một
  hàng, mỗi cột (hàng) được một unit xử lý ở một bước.
- Ước tính chu kỳ từ lịch: mỗi vòng = (bước VN × Z + 3) + (bước CN × Z + 2)
  + 1; 18 vòng. Trùng với chu kỳ đo trên RTL ở mọi tổ hợp đã chạy.
- Mã (1152,580) của da2: không phải QC. Với Z = 32 (36 PE × 32 của da2) có 80
  khối không phải hoán vị vòng (phần PI_3 đổi theo thời gian), với lưới 12×24
  (Z = 48) có 113 → không đặt được lên bank QC; cần mạng hoán vị theo chu kỳ.

## 4. Bộ chọn P_act/C_act (`run.py select`, `mapper.select`)

- Đầu vào: mã, latency tối đa và/hoặc throughput thông tin tối thiểu (lõi, 30
  MHz). Đầu ra: (P_act, C_act) có P+C nhỏ nhất thỏa yêu cầu.
- Chu kỳ lấy từ lần chạy RTL đạt gần nhất cùng SHA RTL khi có (`measured`),
  nếu không thì từ ước tính của mapper (đã trùng RTL ở mọi tổ hợp đo).
- Không suy số PE từ bậc mã; tiêu chí là chu kỳ của lịch.

## 5. Còn dự kiến (chưa hiện thực)

- Wrapper AXI4-Lite cho lõi adaptive (giữ COD1, thêm vùng thanh ghi cấu hình,
  `CORE_CYCLES`), build bitstream PYNQ-Z2 và đo trên board.
- Mã không QC (1152) và lịch layered.
