cat << 'EOF' | sudo bash
#!/bin/bash

echo "🚀 Bắt đầu mở rộng dung lượng ổ đĩa..."

# Mở rộng Logical Volume (LV) với toàn bộ dung lượng còn trống
echo "🛠 Đang mở rộng Logical Volume..."
lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv

# Kiểm tra xem hệ thống tệp là ext4 hay XFS
FILESYSTEM=$(df -T | awk '$2 ~ /ext4|xfs/ {print $2; exit}')

# Mở rộng hệ thống tệp
echo "🛠 Đang mở rộng hệ thống tệp ($FILESYSTEM)..."
if [ "$FILESYSTEM" == "ext4" ]; then
    resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
elif [ "$FILESYSTEM" == "xfs" ]; then
    xfs_growfs /
else
    echo "⚠️ Hệ thống tệp không được hỗ trợ!"
    exit 1
fi

# Hiển thị dung lượng sau khi mở rộng
echo "📊 Dung lượng sau khi mở rộng:"
df -h

echo "✅ Hoàn tất mở rộng dung lượng!"
EOF
