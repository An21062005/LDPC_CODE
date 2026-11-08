# ldpc_datn_adaptive — decoder QC-LDPC thích nghi (đồ án tốt nghiệp)

Một cụm VN/CN unit và một bộ nhớ message **dùng chung**; mã (Z, vị trí và giá
trị dịch của khối), số VN unit hoạt động (P_act) và số CN unit hoạt động
(C_act) được nạp **lúc chạy** vào cùng một phần cứng. Thuật toán, lượng tử,
18 vòng và quy tắc đóng băng quyết định giữ nguyên như `ldpc_da2`.

## Trạng thái

| Hạng mục | Trạng thái |
|---|---|
| Mapper/lập lịch (`script/mapper.py`) | có: sinh bảng, kiểm tra từng chu kỳ (phủ cạnh, cổng bank, đọc trước ghi, định tuyến), ước tính chu kỳ; `selftest` chứng minh kiểm tra không rỗng |
| RTL dùng chung (`code/rtl/adaptive/adaptive_core.sv`) | có: P_phys = 24 VN unit, C_phys = 12 CN unit, 109 bank (hợp các vị trí khối của 648 và 1296), Z ∈ {27, 54} |
| Mã QC (648,324) Z=27 | mô phỏng RTL khớp từng bit với expected và mô hình, đo chu kỳ — các mức P/C trong `outfeed/reports/adaptive.md` |
| Mã QC (1296,648) Z=54 | như trên, cùng RTL/phần cứng |
| Đổi mã và P/C lúc chạy trên cùng phần cứng | plan `mixed`: 648 ↔ 1296 với P/C khác nhau trong một lần mô phỏng |
| Mã (1152,580) của da2 | **chưa hỗ trợ**: không phải QC (phần PI_3 thay đổi theo thời gian); mapper từ chối kèm phân tích khối |
| Bộ chọn P_act/C_act | có (`run.py select`): chọn P+C nhỏ nhất thỏa latency/throughput, dùng chu kỳ đo từ RTL khi có |
| Tổng hợp | OOC lõi trên xc7z020 ở 30 MHz (`run.py synth`); chưa có wrapper AXI/bitstream PYNQ-Z2 |
| Board | chưa: không kết nối/nạp FPGA |

## Lệnh (chạy trong `ldpc_datn_adaptive`)

```powershell
python script/run.py check                 # package phần cứng khớp hw_limits.yaml, Vivado
python script/mapper.py hw                 # sinh lại code/rtl/generated/adaptive_hw_pkg.sv
python script/mapper.py selftest           # lịch hỏng phải bị từ chối
python script/run.py map                   # mọi mã x P_act x C_act -> outfeed/maps
python script/run.py data                  # dữ liệu nhiễu (eye.png, SNR 3 dB) -> outfeed/data
python script/run.py sim --plan mixed      # hoặc qc648, qc1296 (script/config.yaml)
python script/run.py synth                 # synth + place + route OOC lõi, 30 MHz
python script/run.py select --code wifi_1296_r12 --max-latency-us 150
python script/run.py report                # outfeed/reports/adaptive.md
python script/check_config.py              # kiểm tra định dạng mô tả mã
```

`sim` dùng XSim chạy độc lập (`xvlog`/`xelab`/`xsim`). Mỗi đoạn của plan nạp
ảnh cấu hình do mapper sinh qua cổng cấu hình khi lõi rỗi, rồi giải các frame
của mã đó. Đầu ra so với codeword sạch (tiêu chí PASS) và với mô hình Python
(từng bit); mô hình không sinh đầu ra DUT. Thêm một phép thử âm: ghi cấu hình
lúc lõi bận phải bị từ chối (`cfg_err`) và không làm đổi Z.

Tài liệu thiết kế: `docs/thiet_ke_du_kien.md`; giới hạn và lộ trình:
`docs/gioi_han_va_lo_trinh.md`.
