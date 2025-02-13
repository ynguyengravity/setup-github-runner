# Hướng Dẫn Cài Đặt GitHub Runner Tự Động

## Giới Thiệu
Script này giúp bạn thiết lập một GitHub self-hosted runner trên Ubuntu, bao gồm cài đặt Docker, cấp quyền cần thiết, đăng ký runner, và tự động cập nhật hệ thống.

## Yêu Cầu Hệ Thống
- Ubuntu Server 20.04 hoặc mới hơn
- Kết nối Internet
- Tài khoản có quyền `sudo`

## Cách Chạy Script

### 1. Tải Script
```bash
rm setup.sh
wget -O setup.sh https://raw.githubusercontent.com/ynguyengravity/setup-github-runner/master/setup.sh
chmod +x setup.sh
```

### 2. Chạy Script
```bash
./setup.sh <RUNNER_ID>
```
Thay `<RUNNER_ID>` bằng ID runner mong muốn.

### 3. Chạy Lại (Nếu Cần)
Nếu runner đã được cài đặt trước đó và bạn muốn chạy lại script, hãy thêm tham số `force`:
```bash
./setup.sh <RUNNER_ID> force
```

## Các Thành Phần Của Script
- **Cập nhật hệ thống**: Cập nhật và dọn dẹp hệ thống Ubuntu
- **Cài đặt Docker**: Cài đặt Docker nếu chưa có và cấp quyền cho user
- **Cấu hình sudo không cần mật khẩu**: Giúp runner có thể chạy mà không cần nhập mật khẩu sudo
- **Tải và cài đặt GitHub Runner**: Tải xuống runner từ GitHub (phiên bản 2.322.0), giải nén và cấu hình
- **Đăng ký runner với GitHub**: Tự động đăng ký runner với token được cấu hình sẵn
- **Cài đặt runner như một service**: Giúp runner tự động chạy khi hệ thống khởi động
- **Kiểm tra trạng thái runner**: Kiểm tra xem runner có hoạt động đúng hay không

## Cấu Hình Runner
- **Tên Runner**: `runner-<RUNNER_ID>-<IP_ADDRESS>`
- **Labels**: `test-setup,linux,x64`
- **Repository**: ynguyengravity/setup-github-runner

## Xử Lý Sự Cố
1. **Kiểm tra log cài đặt**:
   ```bash
   sudo cat /var/log/github-runner-setup.log
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
- Script sử dụng một token cố định được cấu hình sẵn trong mã nguồn
- Đảm bảo server của bạn có kết nối Internet để tải xuống các thành phần cần thiết
- Lock file được tạo tại `/tmp/github-runner-setup.lock` để tránh chạy trùng lặp
- Script sẽ tự động yêu cầu quyền sudo khi cần thiết

## Liên Hệ & Hỗ Trợ
Nếu gặp vấn đề, hãy mở issue trên repository GitHub hoặc kiểm tra log tại `/var/log/github-runner-setup.log` để tìm lỗi.
