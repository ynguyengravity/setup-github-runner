# Image runner cho scale set vn-gaqc-docker: image chuẩn của ARC + đúng bộ công cụ mà
# runner LXC cũ có (lxc_create_github_actions_runner.master.sh trên branch master).
# Base là Ubuntu 24.04 (noble), giống LXC cũ.
ARG RUNNER_VERSION=2.338.1
FROM ghcr.io/actions/actions-runner:${RUNNER_VERSION}

USER root
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

# Locale + gói nền (LXC cũ: git curl software-properties-common gnupg lsb-release unzip)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      locales ca-certificates curl wget git gnupg lsb-release software-properties-common \
      apt-transport-https unzip zip xz-utils jq \
 && sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen en_US.UTF-8 \
 && update-locale LANG=en_US.UTF-8 \
 && rm -rf /var/lib/apt/lists/*

# Trình duyệt: Chrome, Edge, Firefox (PPA, không dùng snap) + Xvfb và thư viện đồ hoạ
RUN install -d -m 0755 /usr/share/keyrings \
 && curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google-chrome.list \
 && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-edge.gpg \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-edge.gpg] https://packages.microsoft.com/repos/edge stable main" \
      > /etc/apt/sources.list.d/microsoft-edge.list \
 && add-apt-repository -y ppa:mozillateam/ppa \
 && printf 'Package: firefox*\nPin: release o=LP-PPA-mozillateam\nPin-Priority: 1001\n' > /etc/apt/preferences.d/mozillateam-firefox \
 && apt-get update \
 && apt-get install -y \
      google-chrome-stable microsoft-edge-stable firefox \
      xvfb libxss1 libasound2t64 libgtk-3-0t64 libnss3 libdrm2 libgbm1 libxshmfence1 \
      fonts-liberation fonts-noto-color-emoji \
 && rm -rf /var/lib/apt/lists/*

# Node.js 24 (NodeSource) + Playwright (global, deps hệ thống, browser ở thư mục dùng chung)
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
 && apt-get install -y nodejs \
 && npm install -g playwright \
 && npx playwright install-deps \
 && npx playwright install \
 && chmod -R a+rX "$PLAYWRIGHT_BROWSERS_PATH" \
 && rm -rf /var/lib/apt/lists/* /root/.npm

# OpenVPN và công cụ mạng (LXC cũ có /dev/net/tun; pod cần thêm NET_ADMIN + tun, xem guide)
RUN apt-get update \
 && apt-get install -y openvpn net-tools iptables iproute2 iputils-ping dnsutils \
 && rm -rf /var/lib/apt/lists/*

# Docker Compose plugin (LXC cũ cài Docker bằng get.docker.com nên có `docker compose`)
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

# AWS CLI v2
RUN curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip \
 && unzip -q /tmp/awscliv2.zip -d /tmp \
 && /tmp/aws/install \
 && ln -sf /usr/local/bin/aws /usr/bin/aws \
 && rm -rf /tmp/aws /tmp/awscliv2.zip

# Job chạy bằng root (như LXC cũ) nhưng image gốc ghi đè /etc/sudoers chỉ còn %sudo:
# thêm lại dòng root để action gọi `sudo ...` vẫn chạy
RUN echo 'root ALL=(ALL:ALL) NOPASSWD:ALL' >> /etc/sudoers && visudo -c

# Thư viện + font mà .github/scripts/setup-browsers.sh của repo screenshot cài ở MỖI job.
# LXC cũ là runner cố định nên chỉ cài một lần; pod ARC bị xoá sau mỗi job nên phải có sẵn trong image,
# nếu không mỗi job tải lại vài trăm MB (fonts-noto-cjk*) -> bước Install browsers mất ~4 phút thay vì ~0,3.
# Giữ /var/lib/apt/lists ở cuối để `apt update` trong job chỉ tải phần thay đổi.
RUN apt-get update \
 && apt-get install -y \
      xvfb libxss1 libgtk-3-0t64 libnss3 libdrm2 libgbm1 libxshmfence1 libasound2t64 \
      libatk-bridge2.0-0t64 libatspi2.0-0t64 libxdamage1 libxcomposite1 libu2f-udev \
      fontconfig fonts-noto-cjk fonts-noto-cjk-extra fonts-ipafont-gothic fonts-ipafont-mincho \
      fonts-wqy-zenhei fonts-thai-tlwg fonts-kacst fonts-noto-color-emoji fonts-freefont-ttf \
 && fc-cache -f >/dev/null

# Kiểm tra nhanh lúc build: thiếu công cụ nào thì build lỗi ngay
RUN google-chrome --version && microsoft-edge --version && firefox --version \
 && node --version && npm --version && npx playwright --version \
 && openvpn --version | head -1 && docker compose version && aws --version \
 && sudo -n true \
 && fc-list :lang=ja | grep -q . \
 && apt-get update >/dev/null

USER runner
