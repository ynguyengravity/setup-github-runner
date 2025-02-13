# Hướng Dẫn Cài Đặt GitHub Runner Tự Động

## Giới Thiệu
Script này giúp bạn thiết lập một GitHub self-hosted runner trên Ubuntu, bao gồm cài đặt Docker, cấp quyền cần thiết, đăng ký runner, và tự động cập nhật hệ thống. Script được thiết kế để chạy tự động và an toàn trong môi trường production.

## Yêu Cầu Hệ Thống
- Ubuntu Server 20.04 hoặc mới hơn
- Kết nối Internet
- Tài khoản có quyền `sudo`
- Tối thiểu 2GB RAM và 10GB ổ cứng trống

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
Thay `<RUNNER_ID>` bằng ID runner mong muốn (ví dụ: test, prod, dev).

### 3. Chạy Lại (Nếu Cần)
Nếu runner đã được cài đặt trước đó và bạn muốn chạy lại script:
```bash
./setup.sh <RUNNER_ID> force
```

## Tính Năng Chính
1. **Tự Động Hóa Hoàn Toàn**: Không cần thao tác thủ công sau khi chạy script
2. **Đồng Bộ Thời Gian**: Tự động đồng bộ thời gian hệ thống
3. **Quản Lý Docker**: Cài đặt và cấu hình Docker tự động
4. **Bảo Mật**: Cấu hình quyền và permissions an toàn
5. **Bảo Trì Tự Động**: Script bảo trì chạy hàng ngày
6. **Logging**: Ghi log đầy đủ để theo dõi và xử lý sự cố

## Cấu Hình Runner
- **Tên Runner**: `runner-<RUNNER_ID>-<IP_ADDRESS>`
- **Labels**: `test-setup,linux,x64`
- **Repository**: ynguyengravity/setup-github-runner
- **Workspace**: `/opt/actions-runner/_work`

## Các Thành Phần Được Cài Đặt
- Docker Engine
- Git
- Python 3 và pip
- Node.js và npm
- Build Essential tools
- AWS CLI (trong workflow tests)

## Bảo Trì Tự Động
Script tự động thực hiện các tác vụ bảo trì hàng ngày:
- Cập nhật hệ thống
- Dọn dẹp Docker (images, volumes)
- Xóa logs cũ
- Khởi động lại runner

## Xử Lý Sự Cố

### 1. Kiểm Tra Logs
```bash
sudo cat /var/log/github-runner-setup.log
```

### 2. Kiểm Tra Trạng Thái
```bash
# Kiểm tra runner
systemctl status actions.runner.*

# Kiểm tra Docker
docker ps
docker info

# Kiểm tra quyền
ls -l /var/run/docker.sock
groups
```

### 3. Xóa và Cài Lại
```bash
# Dừng service
sudo systemctl stop actions.runner.*

# Xóa cấu hình cũ
cd /opt/actions-runner
sudo ./svc.sh uninstall
sudo ./config.sh remove --unattended

# Xóa thư mục
sudo rm -rf /opt/actions-runner

# Chạy lại script
./setup.sh <RUNNER_ID> force
```

## Bảo Mật
- Lock file ngăn chạy đồng thời nhiều instances
- Quyền hạn được cấu hình tối thiểu cần thiết
- Tự động xóa dữ liệu nhạy cảm sau khi cài đặt
- Kiểm tra và xác thực các bước quan trọng

## Liên Hệ & Hỗ Trợ
- Mở issue trên repository GitHub
- Kiểm tra logs tại `/var/log/github-runner-setup.log`
- Chạy test workflow để kiểm tra cài đặt: `.github/workflows/test-runner.yml`

## Lưu Ý
- Không chạy script với quyền root
- Đảm bảo đủ dung lượng ổ cứng cho Docker images
- Backup dữ liệu quan trọng trước khi chạy lại script với `force`
- Kiểm tra kết nối internet trước khi chạy script
