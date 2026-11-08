# Chạy test và mở waveform

Mở terminal tại `ldpc_da2`. Cấu hình chính: `script/vivado.yaml`; lệnh chạy:
`script/run.py`. Các lệnh không kết nối hoặc nạp FPGA.

## Bắt đầu

Dependency đã cài cục bộ trong `script/.deps` trên workspace này. Khi chuyển máy,
cài một lần, không cần đổi Python toàn hệ thống:

```powershell
python -s -m pip install --target script/.deps -r script/requirements.txt
python script/run.py check
python script/run.py list
python script/run.py sim --test smoke --waves overview --gui
```

## Chọn test

| `--test` | Phạm vi | RTL hiện tại |
|---|---|---|
| `smoke` | 3 transaction, 1 codeword đầu | PASS không có nghĩa toàn bộ decoder đã PASS |
| `regression` | 5 transaction, 3 codeword | Tái hiện lỗi lặp codeword thứ ba |
| `full` | 698 transaction, 696 codeword | Chạy toàn bộ decoder; mất nhiều thời gian |
| `order` | 696 frame raw đã lưu, đọc qua AXI | Chỉ kiểm tra thứ tự đầu ra, không giải mã lại |

`regression` là mặc định để không bỏ sót lỗi đã biết. `--frames` là số
transaction, gồm hai transaction làm đầy pipeline.

```powershell
python script/run.py sim --test regression --waves axi --gui
python script/run.py sim --test full --waves none
python script/run.py sim --test order --waves overview
python script/run.py sim --test regression --frames 10 --waves overview
```

Test FAIL trả exit code 1; vẫn lưu waveform và mở GUI nếu có `--gui`.
Cấu hình sai trả exit code 2 trước khi chạy Vivado.

## Chọn waveform

| `--waves` | Tín hiệu được ghi |
|---|---|
| `none` | Không ghi tín hiệu, phù hợp chạy dài |
| `overview` | Clock/reset, frame, số lỗi, 16 bit đầu codeword, sequencer |
| `axi` | Overview + bus đọc/ghi AXI + codeword đủ 1152 bit |
| `pe` | Overview + core control + một PE được chọn |
| `all` | Tổng hợp các nhóm trên; không dump toàn bộ RAM/36 PE |

```powershell
python script/run.py sim --test regression --waves pe --pe 2,3 --gui
```

`--pe` chọn hàng/cột từ 0..5 **để hiển thị**, không thay số PE phần cứng.
Tên nhóm, radix và đường dẫn tín hiệu có thể sửa trong `waveforms` của YAML.

## Đọc sóng

1. Trong `Frame_Result`, `frame` là transaction; `output_frame` là codeword
   đang đối chiếu; `compare_done=1` báo đã đọc xong kết quả.
2. Xem `frame_errors`, `total_errors`, `first_error_bit`. Vị trí lỗi tính từ 1;
   0 nghĩa chưa có lỗi trong codeword đang kiểm tra.
3. So `decoded_first16`, `expected_first16`, `difference_first16`. Bit đầu
   tiên của dòng output nằm bên trái; mask bằng 1 tại bit khác nhau.
4. Nhóm `Codeword_1152` dùng hex cho gọn; đổi radix sang binary khi cần.
5. Để xem lỗi hiện tại, chọn regression, tìm `output_frame=3` và zoom vùng đó.
   Dữ liệu đang đọc chưa hoàn chỉnh khi `compare_done=0`.

Bus debug chỉ nằm trong testbench, không thay RTL tổng hợp.

## Mở lại, không mô phỏng lại

```powershell
python script/run.py wave --test regression
python script/run.py open --test regression
```

`wave` mở WDB/WCFG đã lưu, `open` mở project để xem hierarchy/source hoặc tự
chạy lại mô phỏng. Mặc định chọn lần chạy gần nhất có dữ liệu phù hợp.
Muốn chọn chính xác, dùng đường dẫn `RUN_DIRECTORY` đã in:

```powershell
python script/run.py wave --run outfeed/s_regression_YYYYMMDDTHHMMSS_ffffffZ
```

`.wdb` chứa dữ liệu theo thời gian, `.wcfg` chứa nhóm và bố cục. File `.log`
trong `.Xil` chỉ là chữ, không chứa sóng. Xem WDB là xem kết quả tĩnh;
muốn thay dữ liệu/test thì chạy `sim`.

## YAML và filelist

```text
script/vivado.yaml         test, frame, tool, threads/jobs, waveform
script/filelists/rtl.f            2 compilation unit dùng chung cho sim/build
script/filelists/full.f           RTL + tb_da2.sv
script/filelists/order.f          RTL + tb_output_order.sv
script/run.py             entry point
script/vivado_cli.py      kiểm tra YAML/filelist, khởi chạy, báo kết quả
script/sources.tcl        nạp source đã resolve từ filelist
script/simulate.tcl       tạo project và chạy XSim
script/waveforms.tcl      ghi tín hiệu và lưu bố cục
script/open_saved.tcl     mở project hoặc WDB/WCFG
```

Đường dẫn trong filelist/YAML tính từ `ldpc_da2`; dùng dấu `/`. Filelist hỗ
trợ dòng source, `+incdir+rtl`, `-f script/filelists/rtl.f` và comment `#`.
22 file lõi được Decoder.v include: không thêm chúng lần nữa làm compilation
unit. Launcher phát hiện vòng lặp filelist và loại source trùng.

```powershell
python script/run.py sim --test regression --waves axi --dry-run
```

`--dry-run` in filelist/cấu hình thực tế, không khởi động Vivado.
Tool được tìm theo thứ tự: `--vivado-bin`, `VIVADO_BIN`, `vivado.bin` trong
YAML, rồi PATH. Mặc định threads=2/jobs=1 để giới hạn bộ nhớ.
YAML không cấu hình lại clock, kiến trúc hoặc số PE.

## Project phần cứng và build

```powershell
python script/run.py project --gui
python script/run.py build
```

Hai lệnh dùng cùng `script/filelists/rtl.f`. `project` chỉ tạo project PYNQ-Z2,
`build` chạy đầy đủ và kiểm tra timing. Chỉ đóng gói khi timing và các test
regression/order cùng PASS trên cùng SHA-256 RTL. Smoke không thay regression.
Timing đã biết là FAIL, WNS −0,579 ns; launcher không sửa lỗi RTL này.
RTL has not been certified for board use.

## File kết quả

Mỗi lần chạy có thư mục riêng `outfeed/s_<test>_<UTC timestamp>` hoặc `outfeed/h_<...>`:

- `status.json`: PASS/FAIL, số lỗi, SHA-256 RTL, đường dẫn WDB/WCFG/project.
- `resolved.json`, `run_config.tcl`: cấu hình và filelist thực tế.
- `logs/vivado.log`: log chính; `p.sim/sim_1/behav/xsim/simulate.log`: log test.
- `waves.wcfg`: bố cục; file WDB nằm trong thư mục XSim.
- `wave_signals.txt`: số tín hiệu được ghi và đường dẫn chưa tìm thấy, nếu có.
- `output_codeword.txt`: các codeword đọc qua AXI.

`outfeed/reports/latest_test_<test>.json` ghi kết quả mới nhất từng test. Không xóa
hoặc ghi đè lần chạy cũ. `wave --check` kiểm tra mở WDB/WCFG ở batch, không mở GUI.
