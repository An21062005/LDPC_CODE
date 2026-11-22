# LDPC FPGA Decoder — RTL verification

Project này giữ lại RTL LDPC của tác giả, bổ sung bản RTL đã sửa và một flow
kiểm chứng tự động bằng ảnh `data/eye.png`.

## Cấu trúc thư mục

| Đường dẫn | Nội dung |
|---|---|
| `Decoder.v`, `Decoder_tb.v`, các thư mục `CNU/`, `VNU/`, ... | RTL gốc của tác giả, giữ nguyên cấu trúc include |
| `fix/` | Bản RTL đã sửa, testbench và unit test |
| `data/` | Ảnh đầu vào |
| `artifacts/` | Metadata và báo cáo compare dạng JSON |
| `verification_logs/` | Log minh chứng ba bước và log Vivado thô |
| `docs/` | Báo cáo Word, bài báo tham khảo cục bộ và hướng dẫn GitHub |
| `generate_input.py` | Ảnh → bit → LDPC encode → AWGN → `input.txt` |
| `run_rtl.py` | Chạy bản RTL trong `fix/` bằng Vivado XSim |
| `compare.py` | So sánh RTL output với clean codeword |
| `run_all.ps1` | Chạy liên tiếp toàn bộ flow |

## Chuẩn bị Python

Khuyến nghị Python 3.11 hoặc 3.12. Với môi trường hiện tại, cài dependency:

```powershell
python -m pip install --upgrade setuptools wheel
python -m pip install numpy scipy numba Pillow
python -m pip install --no-build-isolation pyldpc==0.7.9
```

Vivado 2026.1 tại `D:\vivado\2026.1\Vivado\bin` được tự động dò. Nếu Vivado
nằm ở chỗ khác, đặt biến môi trường trước khi chạy:

```powershell
$env:VIVADO_BIN = "D:\duong-dan-cua-ban\Vivado\bin"
```

## Chạy theo ba bước

Mở PowerShell tại thư mục project rồi chạy:

```powershell
python generate_input.py
python run_rtl.py
python compare.py
```

Ba file dữ liệu chính nằm ngay thư mục gốc để dễ xem:

- `input.txt`: 5-bit LLR đưa vào RTL, gồm payload và hai flush frame.
- `expected_codeword.txt`: clean codeword trước noise.
- `output.txt`: output mới nhất do `run_rtl.py` tạo ra (sẽ xuất hiện sau lần chạy kế tiếp).
- `output_fixed.txt`: kết quả PASS toàn ảnh đã lưu để làm bằng chứng.

Metadata và báo cáo máy đọc được ghi vào `artifacts/`. Với ảnh 224×225,
SNR 20 dB và seed 42, lần kiểm chứng đã lưu có 696 frame, 801.792 bit,
0 bit lỗi, 0 bit X/Z và kết quả `PASS`.

Để chạy gọn bằng một lệnh:

```powershell
powershell -ExecutionPolicy Bypass -File .\run_all.ps1
```

Chạy nhanh với ảnh thu nhỏ:

```powershell
python generate_input.py --resize 8 8
python run_rtl.py
python compare.py
```

## Kiểm tra từng module

```powershell
python fix\run_unit_tests.py
```

Muốn tái hiện lỗi của RTL gốc thay vì bản sửa:

```powershell
python run_rtl.py --rtl original --output output_original.txt
```

## Tài liệu

- Báo cáo sửa lỗi: `docs/Bao_cao_kiem_tra_sua_loi_RTL_LDPC.docx`
- Log kiểm chứng: `verification_logs/README.txt`
- Hướng dẫn đưa project lên GitHub: `docs/GITHUB_UPLOAD.md`

Lưu ý: repository này là bản kiểm chứng và sửa lỗi từ mã nguồn đi kèm công
trình, không phải repository chính thức của tác giả bài báo. File PDF bài báo
được `.gitignore` để chỉ dùng cục bộ và tránh phân phối lại tài liệu có bản quyền.
