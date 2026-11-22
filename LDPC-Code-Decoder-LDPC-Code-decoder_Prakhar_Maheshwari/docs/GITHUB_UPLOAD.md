# Đưa project lên GitHub

## 1. Tạo repository trên GitHub

1. Đăng nhập GitHub và chọn **New repository**.
2. Đặt tên, ví dụ `ldpc-fpga-decoder-verification`.
3. Chọn Public hoặc Private tùy nhu cầu.
4. Không chọn tạo sẵn README, `.gitignore` hay License vì project đã có.
5. Chọn **Create repository**, sau đó sao chép URL HTTPS.

PDF bài báo trong `docs/paper_ldpc_fpga.pdf` đã được `.gitignore`; file này chỉ
được giữ cục bộ và sẽ không được upload.

## 2. Tạo commit đầu tiên

Mở PowerShell và chạy:

```powershell
cd "C:\Users\HOANG AN\Downloads\ldpc_code\LDPC-Code-Decoder-LDPC-Code-decoder_Prakhar_Maheshwari"
git init
git add .
git status
git commit -m "Add LDPC RTL verification flow and fixes"
git branch -M main
```

Nếu Git báo chưa có tên hoặc email, khai báo một lần rồi commit lại:

```powershell
git config --global user.name "TEN CUA BAN"
git config --global user.email "EMAIL_GITHUB_CUA_BAN"
git commit -m "Add LDPC RTL verification flow and fixes"
```

## 3. Nối repository và push

Thay URL dưới đây bằng URL repository vừa tạo:

```powershell
git remote add origin https://github.com/TEN_GITHUB_CUA_BAN/ldpc-fpga-decoder-verification.git
git push -u origin main
```

GitHub có thể mở trình duyệt để yêu cầu đăng nhập. Không gõ mật khẩu GitHub
vào lệnh và không lưu Personal Access Token trong file của project.

## 4. Các lần cập nhật sau

```powershell
git status
git add .
git commit -m "Mo ta thay doi"
git push
```

Trước mỗi lần commit, luôn đọc `git status` để chắc chắn không đưa file tạm,
khóa Word hoặc output Vivado không cần thiết lên repository.
