# Quy tắc làm việc trong ldpc_code

Áp dụng cho toàn bộ workspace. Thực hiện đúng yêu cầu hiện tại của người dùng; các ý tưởng đã thảo luận không tự động trở thành việc được phép triển khai.

- Sửa đơn giản, đúng trọng tâm, với phạm vi thay đổi nhỏ nhất đủ giải quyết yêu cầu.
- Không tự thêm tính năng, cấu hình, adapter, lớp trừu tượng, dependency, thư mục hoặc tài liệu ngoài nhu cầu của công việc đang được giao.
- Không tự refactor, dọn dẹp, đổi tên, di chuyển hoặc xóa những phần không liên quan. Giữ nguyên thay đổi sẵn có của người dùng.
- Đọc code và luồng chạy liên quan trước khi sửa. Ưu tiên tận dụng cách làm hiện có; không tự dựng một luồng thay thế chỉ vì thuận tiện.
- Không tự đổi kiến trúc, thuật toán LDPC, số PE, clock, số vòng lặp, giao tiếp hoặc thứ tự dữ liệu nếu yêu cầu không cho phép.
- Khi người dùng nói “đề xuất”, “thống nhất”, “chưa sửa” hoặc chỉ yêu cầu viết prompt: chỉ trả lời đúng nội dung đó, không tạo hay sửa file.
- Với yêu cầu triển khai rõ ràng: nêu ngắn gọn file và mục đích sửa rồi thực hiện. Không hỏi xác nhận lại các thao tác thông thường đã được cho phép.
- Tự quyết các chi tiết nhỏ trong phạm vi yêu cầu. Nếu thông tin thiếu có thể làm thay đổi chức năng hoặc phạm vi đáng kể, hỏi ngắn gọn; không tự đoán yêu cầu mới.
- Nếu gặp lỗi ngoài phạm vi: báo rõ vị trí, bằng chứng và ảnh hưởng; không âm thầm mở rộng sang sửa lỗi đó.
- Kiểm tra vừa đủ cho thay đổi. Không tự thêm cả hệ thống test hoặc thay testbench/dữ liệu tham chiếu khi không cần thiết; nếu cần bổ sung test, giải thích mục đích.
- Không sửa expected, bỏ kiểm tra hoặc nới tiêu chí để làm kết quả đạt. Không dùng dữ liệu tham chiếu để sinh đầu ra của bộ giải mã.
- Mọi kết quả chạy của từng dự án phải nằm trong đúng thư mục outfeed/ của dự án đó. Không tạo thêm nơi lưu log, waveform, báo cáo hoặc build ở ngoài outfeed/.
- Phân biệt kết quả vừa chạy với báo cáo cũ. Không khẳng định PASS, timing đạt, sẵn sàng nạp board hoặc lợi ích hiệu năng khi chưa có bằng chứng tương ứng.
- Không tự kết nối hay nạp FPGA. Không sửa các dự án tham chiếu khi người dùng yêu cầu giữ nguyên.
- Trả lời tiếng Việt, ngắn gọn: đã sửa gì, kiểm tra gì, còn lỗi hoặc giới hạn nào. Không biến một yêu cầu nhỏ thành kế hoạch lớn.
