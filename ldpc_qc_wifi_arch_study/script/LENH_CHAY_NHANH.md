# Lệnh chạy nhanh

Mọi lệnh chạy trong PowerShell, đứng tại thư mục dự án:

```powershell
cd "C:\Users\HOANG AN\Downloads\ldpc_code\ldpc_da2_qc_wifi"
```

Kết quả nằm trong `outfeed/`.

`open --arch A` mở Vivado GUI với project của lần synth/build **mới nhất** của
kiến trúc đó. Trong Vivado, ở Flow Navigator bấm **Open Synthesized Design**
để xem synth, **Open Implemented Design** để xem impl. Muốn synth/build xong tự
mở GUI luôn thì thêm `--gui` (vd. `python script/run.py build --arch serial --gui`).

Đường dẫn report bên dưới là của lần build hiện có; build lại sẽ có thư mục mới.

---

## 1. Serial (nối tiếp)

| Mục đích | Command |
|---|---|
| Chạy test | `python script/run.py sim --arch serial --test regression` |
| Xem waveform test vừa chạy | `python script/run.py wave --arch serial --test regression` |
| Synth | `python script/run.py synth --arch serial` |
| Impl (synth + implement + bitstream) | `python script/run.py build --arch serial` |
| Mở Vivado GUI xem kết quả synth/impl | `python script/run.py open --arch serial` |

| Report impl | File |
|---|---|
| Tài nguyên | `outfeed\hw\serial_build_20261115T051003Z\reports\utilization_impl.rpt` |
| Timing | `outfeed\hw\serial_build_20261115T051003Z\reports\timing_impl.rpt` |
| Công suất | `outfeed\hw\serial_build_20261115T051003Z\reports\power_impl.rpt` |

---

## 2. Partly-parallel (bán song song)

| Mục đích | Command |
|---|---|
| Chạy test | `python script/run.py sim --arch partly_parallel --test regression` |
| Xem waveform test vừa chạy | `python script/run.py wave --arch partly_parallel --test regression` |
| Synth | `python script/run.py synth --arch partly_parallel` |
| Impl (synth + implement + bitstream) | `python script/run.py build --arch partly_parallel` |
| Mở Vivado GUI xem kết quả synth/impl | `python script/run.py open --arch partly_parallel` |

| Report impl | File |
|---|---|
| Tài nguyên | `outfeed\hw\partly_parallel_build_20261115T044633Z\reports\utilization_impl.rpt` |
| Timing | `outfeed\hw\partly_parallel_build_20261115T044633Z\reports\timing_impl.rpt` |
| Công suất | `outfeed\hw\partly_parallel_build_20261115T044633Z\reports\power_impl.rpt` |

---

## 3. Fully-parallel (song song)

Vượt tài nguyên chip (khoảng 238% LUT) nên **không implement được**, chỉ chạy được test và synth.

| Mục đích | Command |
|---|---|
| Chạy test | `python script/run.py sim --arch fully_parallel --test regression` |
| Xem waveform test vừa chạy | `python script/run.py wave --arch fully_parallel --test regression` |
| Synth | `python script/run.py synth --arch fully_parallel` |
| Mở Vivado GUI xem kết quả synth | `python script/run.py open --arch fully_parallel` |

| Report synth | File |
|---|---|
| Tài nguyên | `outfeed\hw\fully_parallel_synth_20261115T062734Z\reports\utilization_synth.rpt` |

---

## 4. So sánh 3 kiến trúc

| Mục đích | Command |
|---|---|
| Tạo bảng so sánh (kết quả ở `outfeed\reports\comparison.md`) | `python script/run.py report` |

---

## 5. Vẽ đồ thị BER/FER

| Bước | Mục đích | Command |
|---|---|---|
| 1 | Chạy sim BER cho 1 kiến trúc ở 1 mức SNR (lâu) | `python script/run.py sim --arch partly_parallel --test ber_snr2p0 --waves none` |
| 2 | In bảng BER/FER và vẽ đồ thị | `python ber_fer/eval_ber_fer.py` |

- Bước 1: đổi `--arch` thành `serial`, `partly_parallel` hoặc `fully_parallel`;
  đổi `--test` thành `ber_snr1p0`, `ber_snr1p5`, `ber_snr2p0`, `ber_snr2p5` hoặc `ber_snr3p0`.
  Mỗi kiến trúc cần ít nhất 2 mức SNR thì mới có đường để vẽ.
- Bước 2 cần cài `numpy` và `matplotlib`.

---

## 6. Các test (giá trị cho `--test`)

| Test | Mục đích |
|---|---|
| `smoke` | 1 codeword, nhanh nhất |
| `regression` | 3 codeword (mặc định) |
| `noisy` | 20 codeword nhiễu SNR 3 dB |
| `full` | Toàn bộ 1245 codeword, rất lâu |
