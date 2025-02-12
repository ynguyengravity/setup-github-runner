# Hướng Dẫn Cài Đặt GitHub Runner Tự Động

## Giới Thiệu
Script này giúp bạn thiết lập một GitHub self-hosted runner trên Ubuntu, bao gồm cài đặt Docker, cấp quyền cần thiết, đăng ký runner, và tự động cập nhật hệ thống.

## Yêu Cầu Hệ Thống
- Ubuntu Server 20.04 hoặc mới hơn
- Kết nối Internet
- Tài khoản có quyền `sudo`
- Token GitHub có quyền `repo` và `actions:read/write`

## Cách Chạy Script

### 1. Chạy Lần Đầu
Chạy lệnh sau để cài đặt runner:
```bash
bash <(curl -sL https://raw.githubusercontent.com/ynguyengravity/setup-github-runner/master/setup.sh) <RUNNER_ID> <GITHUB_TOKEN>
```
Thay `your-repo` bằng repository chứa script, `<RUNNER_ID>` bằng ID runner mong muốn, và `<GITHUB_TOKEN>` bằng token GitHub hợp lệ.

### 2. Chạy Lại (Bắt Buộc)
Nếu runner đã được cài đặt trước đó và bạn muốn chạy lại script, hãy thêm tham số `force`:
```bash
bash <(curl -sL https://raw.githubusercontent.com/ynguyengravity/setup-github-runner/master/setup.sh) <RUNNER_ID> <GITHUB_TOKEN> force
```

## Các Thành Phần Của Script
- **Cập nhật hệ thống**: Cập nhật và dọn dẹp hệ thống Ubuntu
- **Cài đặt Docker**: Cài đặt Docker nếu chưa có và cấp quyền cho user
- **Cấu hình sudo không cần mật khẩu**: Giúp runner có thể chạy mà không cần nhập mật khẩu sudo
- **Tải và cài đặt GitHub Runner**: Tải xuống runner từ GitHub, giải nén và cấu hình
- **Đăng ký runner với GitHub**: Tự động lấy token và đăng ký runner
- **Cài đặt runner như một service**: Giúp runner tự động chạy khi hệ thống khởi động
- **Kiểm tra trạng thái runner**: Kiểm tra xem runner có hoạt động đúng hay không

## Xử Lý Sự Cố
1. **Kiểm tra log cài đặt**:
   ```bash
   cat /var/log/github-runner-setup.log
   ```
2. **Kiểm tra trạng thái runner**:
   ```bash
   systemctl status actions.runner
   ```
3. **Xóa runner và cài lại**:
   ```bash
   cd ~/actions-runner
   ./config.sh remove --unattended
   rm -rf ~/actions-runner
   ```
   Sau đó, chạy lại script với tham số `force`.

## Ghi Chú
- Token GitHub chỉ có hiệu lực trong một khoảng thời gian ngắn, nếu script thất bại khi lấy token, hãy tạo token mới.
- Đảm bảo server của bạn có kết nối Internet để tải xuống các thành phần cần thiết.

## Liên Hệ & Hỗ Trợ
Nếu gặp vấn đề, hãy mở issue trên repository GitHub chứa script hoặc kiểm tra log để tìm lỗi.

