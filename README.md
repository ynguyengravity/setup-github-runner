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
./setup.sh test force
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

## Reset Machine ID

### Giới Thiệu
Script `reset-machine-id.sh` được sử dụng để reset machine-id của hệ thống, thường dùng khi:
- Clone VM hoặc container
- Cần tạo một instance mới với ID duy nhất
- Tránh xung đột machine-id trong hệ thống

### Điều Kiện Reset Machine ID
Script sẽ thực hiện reset machine-id trong các trường hợp sau:

1. **Khi IP Không Thay Đổi**:
   - Script lưu IP ban đầu với file `/root/.initial_ip`
   - Mỗi lần chạy, script so sánh IP hiện tại với IP đã lưu
   - Nếu IP giống nhau, script sẽ:
     * Backup machine-id cũ
     * Tạo machine-id mới
     * Reboot hệ thống
     * Tự động chạy lại sau khi reboot để kiểm tra IP mới

2. **Khi IP Đã Thay Đổi**:
   - Script phát hiện IP hiện tại khác với IP đã lưu
   - Script sẽ dừng quá trình reset và:
     * Xóa file lưu IP ban đầu
     * Disable service tự động reset
     * Dọn dẹp các file tạm
     * Kết thúc quá trình

3. **Các Trường Hợp Đặc Biệt**:
   - Lần đầu chạy (chưa có file lưu IP)
   - Sau khi reboot (service tự động chạy)
   - Khi chạy thủ công với sudo

### Cách Sử Dụng
1. **Chạy Script**:
```bash
rm reset-machine-id.sh
wget -O reset-machine-id.sh https://raw.githubusercontent.com/ynguyengravity/setup-github-runner/master/reset-machine-id.sh
chmod +x reset-machine-id.sh
sudo ./reset-machine-id.sh
```

2. **Theo Dõi Quá Trình**:
- Log file: `/var/log/machine-id-reset.log`
- Backup: `/root/machine-id-backup`

3. **Quy Trình Hoạt Động**:
- Kiểm tra và lưu IP ban đầu
- Tự động backup machine-id cũ
- Tạo machine-id mới
- Tự động reboot nếu cần
- Dọn dẹp sau khi hoàn thành

### Tính Năng An Toàn
1. **Backup Tự Động**:
   - Lưu trữ machine-id cũ với timestamp
   - Tự động xóa backup cũ sau 30 ngày
   - Quyền truy cập an toàn (600)

2. **Kiểm Tra Hệ Thống**:
   - Kiểm tra không gian đĩa (tối thiểu 500MB)
   - Xác thực quyền root
   - Kiểm tra trạng thái network

3. **Xử Lý Lỗi**:
   - Log chi tiết các bước thực hiện
   - Thông báo lỗi rõ ràng
   - Rollback khi gặp lỗi

### Theo Dõi và Xử Lý Sự Cố
1. **Kiểm Tra Log**:
```bash
sudo tail -f /var/log/machine-id-reset.log
```

2. **Kiểm Tra Backup**:
```bash
ls -la /root/machine-id-backup/
```

3. **Kiểm Tra Service**:
```bash
systemctl status machine-id-reset
```

4. **Khôi Phục Backup**:
```bash
# Tìm file backup gần nhất
latest_backup=$(ls -t /root/machine-id-backup/machine-id.* | head -1)
# Khôi phục
sudo cp "$latest_backup" /etc/machine-id
```

### Lưu Ý Quan Trọng
1. **Trước Khi Chạy**:
   - Backup dữ liệu quan trọng
   - Đảm bảo đủ dung lượng ổ cứng
   - Kiểm tra kết nối mạng

2. **Sau Khi Chạy**:
   - Kiểm tra log để xác nhận thành công
   - Verify machine-id mới
   - Kiểm tra các service quan trọng

3. **Xử Lý Sự Cố**:
   - Kiểm tra log file
   - Sử dụng backup để khôi phục
   - Liên hệ support nếu cần

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

https://github.dev/Gravity-Global/gravity-jenkins-automation-performance-check-v2-10-2023/.github/workflows/tool.yml@master
https://github.dev/Gravity-Global/gravity-jenkins-automation-frontend-checklist-v2-10-2023/.github/workflows/tool.yml@master
https://github.dev/Gravity-Global/gravity-jenkins-automation-spell-check-v2-10-2023/.github/workflows/tool.yml@master
https://github.dev/Gravity-Global/gravity-jenkins-automation-redirect-check-v2-10-2023/.github/workflows/tool.yml@master
https://github.dev/Gravity-Global/gravity-jenkins-automation-links-check-v2-10-2023/.github/workflows/tool.yml@master
https://github.dev/Gravity-Global/gravity-jenkins-automation-sitemap-check-urls-v2-10-2023/.github/workflows/tool.yml@master
https://github.dev/Gravity-Global/gravity-jenkins-automation-check-google-indexed-v2-10-2023/.github/workflows/tool.yml@master
https://github.dev/Gravity-Global/gravity-jenkins-automation-functionalities-check-v2-10-2023/.github/workflows/tool.yml@master
https://github.dev/Gravity-Global/gravity-jenkins-automation-screenshot-v2-10-2023/.github/workflows/tool.yml@master
https://github.dev/Gravity-Global/gravity-jenkins-automation-compare-headers-10-2023/.github/workflows/tool.yml@master
https://github.dev/Gravity-Global/gravity-master-report-03-2022/.github/workflows/tool.yml@master