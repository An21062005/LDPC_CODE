# LDPC đồ án 2

Thư mục gốc có `code/`, `script/` và một thư mục kết quả duy nhất `outfeed/`.

- `code/rtl/`: RTL decoder và wrapper AXI, giữ nguyên kiến trúc.
- `code/tests/`: testbench hiện có.
- `code/data/`: input LLR và reference từ dữ liệu ảnh eye.png có sẵn.
- `code/board_files_repo/`: preset PYNQ-Z2.
- `script/`: Python, Tcl, YAML, filelist và hướng dẫn.
- `outfeed/`: tự tạo khi chạy, chứa project, waveform, log và báo cáo.

Chạy trong `ldpc_da2`:

```powershell
python script/run.py check
python script/run.py list
python script/run.py sim --test smoke --waves overview --gui
python script/run.py sim --test regression --waves axi --gui
python script/run.py project --gui
```

Sau khi mô phỏng, mở lại waveform mà không chạy lại:

```powershell
python script/run.py wave --test regression
```

Cấu hình: `script/vivado.yaml`. Hướng dẫn: [RUN_VIVADO.md](RUN_VIVADO.md).
Dependency nằm trong `script/.deps`. Khi chuyển máy:

```powershell
python -s -m pip install --target script/.deps -r script/requirements.txt
```

Các profile smoke/regression hiện dùng testbench AXI đã bổ sung, không phải
Decoder_tb.v có sẵn của bản fix. Smoke chỉ đối chiếu codeword đầu; regression
đã tái hiện sai lệch 270 bit ở codeword thứ ba. Kết quả này chưa đủ để kết luận
lõi RTL gốc sai. Build trước đó chưa đạt timing (WNS −0,579 ns).
Không tự nạp FPGA.
