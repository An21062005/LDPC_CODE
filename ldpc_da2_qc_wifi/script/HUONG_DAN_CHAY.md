# Hướng dẫn chạy ldpc_da2_qc_wifi

Mọi lệnh chạy bằng **một script duy nhất** `script/run.py`, đứng tại thư mục
`ldpc_da2_qc_wifi`:

```powershell
cd "C:\Users\HOANG AN\Downloads\ldpc_code\ldpc_da2_qc_wifi"
python script/run.py <lệnh> [option]
```

Mọi kết quả (log, waveform, project Vivado, report) nằm trong `outfeed/`.
Không lệnh nào kết nối hay nạp FPGA.

## 1. Chuẩn bị (làm 1 lần)

- Python 3 có `numpy`, `scipy`, `pyyaml`, `pillow`, `pyldpc`.
- Kiểm tra đường dẫn Vivado và Questa trong `script/config.yaml`
  (`vivado.bin`, `questa.bin`).
- Kiểm tra cấu hình:

```powershell
python script/run.py check
```

Thấy `CONFIG_PASS` là được.

## 2. Ba kiến trúc

| Tên dùng trong `--arch` | Kiến trúc |
|---|---|
| `fully_parallel` | Song song: 648 VN + 324 CN, nối cứng theo H |
| `partly_parallel` | Bán song song (QC): 24 PE + 12 CN unit |
| `serial` | Nối tiếp: 1 VN unit + 1 CN unit |

`fully_parallel` vượt tài nguyên xc7z020 (khoảng 238% LUT) nên implement sẽ
lỗi. Với kiến trúc này chỉ nên chạy `sim` và `synth`.

## 3. Cách nhanh nhất: lệnh `flow`

Sửa mục `flow` trong `script/config.yaml`:

```yaml
flow:
  architectures: [fully_parallel, partly_parallel, serial]
  steps: [sim, synth, impl]
  test: regression
```

| Bước (`steps`) | Làm gì |
|---|---|
| `sim` | Chỉ kiểm tra chức năng (mô phỏng test `test`) |
| `synth` | Chỉ tổng hợp, xuất report tài nguyên |
| `impl` | Synth + implement + bitstream (giống `build`). Có `impl` thì không chạy `synth` riêng |

Bỏ kiến trúc hay bước nào khỏi danh sách là nó không chạy. Sau đó:

```powershell
python script/run.py flow
```

Ghi đè config ngay trên dòng lệnh (cách nhau bằng dấu phẩy, không dấu cách):

```powershell
python script/run.py flow --arch serial,partly_parallel --steps sim,impl
python script/run.py flow --arch fully_parallel --steps sim,synth --test noisy
python script/run.py flow --dry-run          # chỉ in sẽ chạy gì, không chạy
```

Các bước chạy lần lượt theo thứ tự kiến trúc trong danh sách, mỗi kiến trúc
theo thứ tự `sim`, `synth`, `impl`. Nếu một bước lỗi, các bước sau vẫn chạy.
Cuối cùng in `FLOW_SUMMARY`, mỗi bước một dòng:

| Kết quả | Ý nghĩa |
|---|---|
| `PASS` | Sim đạt, hoặc synth xong |
| `PASS, timing met` | Impl xong, timing đạt |
| `PASS, timing NOT met` | Impl xong nhưng timing không đạt |
| `FAIL (synth)` / `FAIL (impl)` | Vivado lỗi ở bước đó |
| `FAIL` | Sim không đạt hoặc tool lỗi |
| `DRY_RUN` | Chạy với `--dry-run`, chưa chạy thật |

## 3b. Giao diện web (chọn kiến trúc, bấm Run, xem số liệu)

```powershell
python web/server.py                 # tự mở http://127.0.0.1:8765
python web/server.py --port 9000 --no-browser
```

Trang web gồm 4 phần:

1. Chọn kiến trúc (song song, bán song song, nối tiếp), chọn test và bước
   (`sim`, `synth`, `impl`), rồi bấm **Run**.
2. Log chạy trực tiếp (XSim, Vivado), có thanh đếm codeword và bit lỗi khi
   chạy sim. Nút **Dừng** hủy bước đang chạy.
3. Số liệu của kiến trúc đang chọn: chức năng, hiệu năng lõi (chu kỳ,
   latency, throughput) và phần cứng (LUT/FF/BRAM, timing, Fmax, công suất,
   bitstream).
4. So sánh 3 kiến trúc bằng biểu đồ và bảng.

Bên trong, nút Run chạy đúng lệnh
`python script/run.py flow --arch A --steps S --test T`, nên kết quả vẫn
nằm trong `outfeed/` như khi chạy bằng dòng lệnh. Số liệu đọc từ
`outfeed/reports/`. Server chỉ mở cho máy này (127.0.0.1), mỗi lúc chạy một
việc. Tắt server bằng Ctrl+C.

## 4. Từng lệnh riêng

| Lệnh | Làm gì |
|---|---|
| `check` | Kiểm tra config, filelist, RTL sinh từ H, LUT, tìm Vivado |
| `list` | Liệt kê kiến trúc, test, profile sóng |
| `data` | Sinh dữ liệu test vào `code/data/<tên dataset>/` (sim cũng tự sinh nếu thiếu) |
| `model --test T` | Chạy mô hình Python bit-accurate, không cần Vivado |
| `sim --arch A --test T` | Mô phỏng kiểm tra chức năng |
| `wave` | Mở lại waveform đã lưu |
| `project --arch A` | Chỉ tạo project Vivado (block design PS7 + AXI), không synth |
| `synth --arch A` | Tạo project + synth, dừng sau report tài nguyên |
| `build --arch A` | Tạo project + synth + implement + bitstream + report timing/power |
| `open --arch A` | Mở lại project Vivado đã tạo gần nhất |
| `flow` | Chạy nhiều kiến trúc và nhiều bước (mục 3) |
| `package --arch A` | Kiểm tra lại build mới nhất; đủ điều kiện thì chép gói nạp board |
| `report` | Bảng so sánh kết quả mới nhất → `outfeed/reports/comparison.md` |

Ví dụ:

```powershell
python script/run.py sim --arch partly_parallel --test regression
python script/run.py sim --arch serial --test noisy --waves core --gui
python script/run.py sim --test units
python script/run.py synth --arch fully_parallel
python script/run.py build --arch partly_parallel
python script/run.py project --arch serial --gui
python script/run.py open --arch partly_parallel
python script/run.py wave --arch serial --test noisy
python script/run.py report
```

## 5. Option

| Option | Dùng với | Ý nghĩa |
|---|---|---|
| `--arch A` | sim, project, synth, build, open, wave, package | Chọn kiến trúc. Bỏ trống thì lấy `defaults.architecture` (`partly_parallel`). Với `flow` được ghi nhiều kiến trúc, cách nhau dấu phẩy |
| `--steps S` | flow | `sim`, `synth`, `impl`, cách nhau dấu phẩy |
| `--test T` | sim, model, flow, wave | Chọn test (bảng mục 6). Mặc định `regression` |
| `--frames F` | sim, model | Đổi số transaction của test. Phải ≥ 3 (2 transaction đầu bị bỏ) |
| `--waves P` | sim, flow | Ghi sóng: `none`, `overview` (mặc định), `axi`, `core`, `all` |
| `--gui` | sim, project, synth, build | Mở Vivado GUI (hoặc Questa) sau khi chạy xong. Sim cần `--waves` khác `none` |
| `--sim xsim\|questa` | sim, flow | Chọn trình mô phỏng (mặc định XSim) |
| `--run DIR` | wave, open | Mở một lần chạy cụ thể thay vì lần mới nhất |
| `--check` | wave, open | Mở thử ở chế độ batch để kiểm tra, không bật GUI |
| `--dry-run` | sim, project, synth, build, flow, wave, open | Chỉ in cấu hình sẽ chạy, không chạy |
| `--vivado-bin DIR` | mọi lệnh dùng Vivado | Ghi đè đường dẫn Vivado trong config |
| `--config FILE` | mọi lệnh | Dùng file config khác `script/config.yaml` |
| `--rescan DIR` | sim | Đọc lại log của một lần sim đã có, tạo lại `status.json`, không mô phỏng lại |

## 6. Các test

| Test | Nội dung | Ghi chú |
|---|---|---|
| `units` | So `VNU_G`/`CNU_G` với `VNU.v`/`CNU.v` của da2, 200 000 vector ngẫu nhiên | Không phụ thuộc kiến trúc |
| `smoke` | AXI, 3 transaction, 1 codeword | Nhanh nhất |
| `regression` | AXI, 5 transaction, 3 codeword | Mặc định |
| `noisy` | AXI, 22 transaction, 20 codeword SNR 3 dB, so với codeword đúng và mô hình Python | |
| `full` | AXI, 1247 transaction, toàn bộ 1245 codeword | Rất lâu |
| `core` | Chỉ lõi, không AXI, dữ liệu nhiễu, đo chu kỳ giải mã | |

## 7. Kết quả nằm ở đâu

| Thư mục | Nội dung |
|---|---|
| `outfeed/sim/<arch>_<test>_<thời gian>/` | Log mô phỏng, waveform, `status.json` |
| `outfeed/hw/<arch>_<project\|synth\|build>_<thời gian>/` | Project Vivado `p.xpr`, `vivado.log`, `reports/`, `status.json` |
| `outfeed/reports/` | `latest_sim_*.json`, `latest_build_*.json`, `comparison.md` |
| `code/data/<tên dataset>/` | Dữ liệu test sinh ra từ `eye.png` (không nằm trong `outfeed/`) |
| `outfeed/artifacts/<build>/` | Gói nạp board (`ldpc.bit`, `ldpc.hwh`, `run_board.py`) |

`package` chỉ chép gói khi đủ cả 3 điều kiện: có bitstream, timing đạt, và
`regression` + `noisy` PASS trên cùng phiên bản RTL với bản build.
Chạy `synth` sẽ ghi đè dòng build của kiến trúc đó trong `report`.
Bitstream cũ trong `outfeed/hw/` không bị xóa.

## 8. Các file trong `script/`

| File | Vai trò |
|---|---|
| `run.py` | Script duy nhất bạn chạy |
| `config.yaml` | Cấu hình: Vivado, kiến trúc, test, `flow`, waveform |
| `create_project.tcl` | `run.py` gọi để Vivado tạo project, synth, impl |
| `open_saved.tcl` | `run.py` gọi để mở lại project hoặc waveform |
| `filelists/*.f` | Danh sách file RTL của từng kiến trúc |
| `ldpc_common.py` | Thư viện chung: dựng ma trận H, LUT, mô hình giải mã Python |
| `gen_rtl.py` | Sinh bảng RTL từ H vào `code/rtl/generated/` |
| `gen_data.py` | Sinh dữ liệu test (ảnh → mã hóa → nhiễu → LLR 5 bit) |
| `run_board.py` | Chạy trên PYNQ-Z2 (được chép vào gói board), không chạy trên PC |
