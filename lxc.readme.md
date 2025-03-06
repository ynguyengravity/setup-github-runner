# Hướng Dẫn Tạo GitHub Actions Runner Trên LXC Container

## Giới Thiệu

Script `lxc_create_github_actions_runner.sh` giúp tự động tạo và cấu hình LXC container trên Proxmox VE để chạy GitHub Actions Runner cho tổ chức Gravity-Global. Runner được tạo sẽ tự động đăng ký với GitHub và sẵn sàng chạy các workflows.

## Yêu Cầu Hệ Thống

- Proxmox VE 7.0 trở lên
- Quyền truy cập SSH vào máy chủ Proxmox với quyền root
- GitHub Personal Access Token với quyền `admin:org`
- Kết nối Internet

## Chuẩn Bị GitHub Token

1. Đăng nhập vào tài khoản GitHub của bạn
2. Truy cập [GitHub Settings > Developer Settings > Personal Access Tokens > Tokens (classic)](https://github.com/settings/tokens)
3. Chọn "Generate new token" > "Generate new token (classic)"
4. Đặt tên và chọn thời hạn cho token
5. Chọn scope `admin:org` (bao gồm `write:org` và `read:org`)
6. Nhấn "Generate token"
7. Sao chép token - **lưu ý**: token chỉ hiển thị một lần

### Cách Đặt GitHub Token Làm Biến Môi Trường

Để tránh phải nhập token mỗi lần chạy script, bạn có thể đặt token làm biến môi trường:

1. **Đặt biến môi trường tạm thời** (chỉ có hiệu lực cho phiên hiện tại):
   ```bash
   export GITHUB_TOKEN="ghp_your_token_here"
   ```

2. **Đặt biến môi trường vĩnh viễn** (sẽ có hiệu lực cho tất cả các phiên mới):
   - Thêm vào file `~/.bashrc` hoặc `~/.bash_profile`:
     ```bash
     echo 'export GITHUB_TOKEN="ghp_your_token_here"' >> ~/.bashrc
     source ~/.bashrc
     ```

3. **Kiểm tra biến môi trường**:
   ```bash
   echo $GITHUB_TOKEN
   ```

4. **Sử dụng token trong một lần chạy**:
   ```bash
   GITHUB_TOKEN="ghp_your_token_here" ./lxc_create_github_actions_runner.sh
   ```

## Cách Sử Dụng Script

### 1. Tải Script

```bash
wget -O lxc_create_github_actions_runner.sh https://raw.githubusercontent.com/ynguyengravity/setup-github-runner/master/lxc_create_github_actions_runner.sh
chmod +x lxc_create_github_actions_runner.sh
```

### 2. Chạy Script

```bash
GITHUB_TOKEN="" bash ./lxc_create_github_actions_runner.sh
```

Khi được yêu cầu, nhập GitHub token đã tạo ở bước trước.

### 3. Theo Dõi Quá Trình

Script sẽ tự động:
- Tải template Ubuntu 22.04 LTS
- Tạo LXC container với ID tự động
- Cấu hình network với DHCP
- Cài đặt Docker trong container
- Đăng ký runner với tổ chức Gravity-Global
- Cấu hình runner với labels và runner group đã chỉ định

### 4. Kiểm Tra Kết Quả

- Sau khi script hoàn tất, bạn sẽ thấy thông tin về:
  - Container ID
  - Runner name
  - Runner labels
  - Runner group

- Kiểm tra runner trên GitHub:
  1. Truy cập [GitHub > Gravity-Global > Settings > Actions > Runners](https://github.com/organizations/Gravity-Global/settings/actions/runners)
  2. Xác nhận runner mới đã online và sẵn sàng

## Cấu Hình Script

Script đã được cấu hình sẵn với các thiết lập sau:

- **Labels**: `vn-gaqc-docker,test-setup`
- **Runner Group**: `VN-Team`
- **Organization**: `Gravity-Global`
- **Resources**: 4 CPU cores, 4GB RAM, 20GB storage
- **Network**: DHCP trên bridge `vmbr1`

### Tùy Chỉnh Cấu Hình

Nếu muốn thay đổi các cấu hình mặc định, bạn có thể chỉnh sửa các biến sau trong script:

```bash
PCTSIZE="20G"              # Kích thước ổ đĩa
RUNNER_LABELS="vn-gaqc-docker,test-setup"  # Các labels cho runner
RUNNER_GROUP="VN-Team"     # Nhóm runner
```

Để chỉnh sửa tài nguyên container (CPU, RAM), thay đổi các tham số sau:

```bash
-cores 4 \
-memory 4096 \
-swap 4096 \
```

## Xử Lý Sự Cố

### Lỗi "Failed to get runner token"

- Kiểm tra lại token GitHub, đảm bảo nó có đủ quyền `admin:org`
- Xác nhận token chưa hết hạn
- Kiểm tra kết nối internet từ máy chủ Proxmox

### Lỗi Docker trong LXC

- Đảm bảo container được tạo với tùy chọn `nesting=1`
- Kiểm tra xem AppArmor có được cấu hình đúng không

### Runner không hiển thị trong GitHub

- Kiểm tra logs trong container:
  ```bash
  pct enter <PCTID>
  cd actions-runner
  cat _diag/*.log
  ```

## Quản Lý Runner

### Truy Cập Container

```bash
pct enter <PCTID>
```

### Xem Trạng Thái Runner

```bash
cd actions-runner
./svc.sh status
```

### Khởi Động Lại Runner

```bash
cd actions-runner
./svc.sh restart
```

### Xem Logs

```bash
cd actions-runner
cat _diag/*.log
```

## Lưu Ý

- Runner được cấu hình để chạy với quyền root trong container
- Hostname và tên runner bao gồm ID container và ngày tạo (định dạng YYYYMMDD)
- Không chia sẻ GitHub token với người khác

## Liên Hệ Hỗ Trợ

Nếu bạn gặp vấn đề khi sử dụng script, vui lòng liên hệ với team DevOps hoặc tạo issue trên repository GitHub. 