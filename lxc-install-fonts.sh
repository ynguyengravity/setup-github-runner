#!/usr/bin/env bash
# =============================================================================
# lxc-install-fonts.sh
# Scan tất cả LXC container đang chạy trên Proxmox và install fonts cho browser
#
# Cách dùng:
#   ./lxc-install-fonts.sh              # install cho tất cả container đang running
#   ./lxc-install-fonts.sh 101 102      # chỉ install cho container ID cụ thể
#   ./lxc-install-fonts.sh --dry-run    # chỉ liệt kê, không install
# =============================================================================

set -euo pipefail

# --- Colors ---
R='\033[0m'
BOLD='\033[1m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
CYAN='\033[36m'
DIM='\033[2m'

log()     { echo -e "${YELLOW}[•] $*${R}"; }
ok()      { echo -e "${GREEN}[✔] $*${R}"; }
err()     { echo -e "${RED}[✘] $*${R}"; }
info()    { echo -e "${CYAN}[i] $*${R}"; }
dim()     { echo -e "${DIM}    $*${R}"; }

# --- Parse args ---
DRY_RUN=false
SPECIFIC_IDS=()

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        [0-9]*)    SPECIFIC_IDS+=("$arg") ;;
        *)         echo "Unknown arg: $arg"; exit 1 ;;
    esac
done

FONT_PACKAGES=(
  # Core / Web-safe
  fonts-liberation
  fonts-liberation2
  fonts-dejavu-core
  fonts-dejavu-extra
  ttf-ubuntu-font-family
  # Emoji
  fonts-noto-color-emoji
  # CJK: Chinese / Japanese / Korean
  fonts-noto-cjk
  fonts-noto-cjk-extra
  fonts-wqy-zenhei
  fonts-wqy-microhei
  fonts-ipafont-gothic
  fonts-ipafont-mincho
  fonts-unfonts-core
  # Arabic / RTL
  fonts-kacst
  fonts-kacst-one
  fonts-arabeyes
  # Indian / South Asian
  fonts-indic
  # Thai / Southeast Asian
  fonts-thai-tlwg
  fonts-tlwg-loma-otf
  # Cyrillic / Eastern European
  xfonts-cyrillic
  xfonts-scalable
  # Broad coverage fallback
  fonts-freefont-ttf
  fonts-unifont
  # Font tooling
  fontconfig
  fontconfig-config
)

PACKAGES_STR="${FONT_PACKAGES[*]}"

# --- Check Proxmox ---
if ! command -v pct &>/dev/null; then
    err "Lệnh 'pct' không tìm thấy. Script này phải chạy trên Proxmox host."
    exit 1
fi

# --- Get container list ---
if [ ${#SPECIFIC_IDS[@]} -gt 0 ]; then
    CONTAINER_IDS=("${SPECIFIC_IDS[@]}")
    info "Chế độ: chỉ install cho container ID: ${CONTAINER_IDS[*]}"
else
    mapfile -t CONTAINER_IDS < <(pct list | awk 'NR>1 && $2=="running" {print $1}')
    info "Chế độ: tất cả container đang running"
fi

if [ ${#CONTAINER_IDS[@]} -eq 0 ]; then
    err "Không tìm thấy container nào đang running."
    exit 0
fi

# --- Summary ---
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${R}"
echo -e "${BOLD}║         LXC Browser Font Installer                  ║${R}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${R}"
echo ""
info "Tìm thấy ${#CONTAINER_IDS[@]} container: ${CONTAINER_IDS[*]}"
$DRY_RUN && echo -e "${YELLOW}  ⚠ DRY-RUN mode — không thực sự install${R}"
echo ""

# --- Counters ---
SUCCESS=0
FAILED=0
SKIPPED=0

# --- Install function ---
install_fonts_on() {
    local CTID="$1"
    local NAME
    NAME=$(pct config "$CTID" 2>/dev/null | awk -F': ' '/^hostname:/{print $2}')
    NAME="${NAME:-container-$CTID}"

    echo -e "${BOLD}┌─ Container ${CYAN}$CTID${R}${BOLD} ($NAME)${R}"

    # Kiểm tra container có đang running không
    local STATUS
    STATUS=$(pct status "$CTID" 2>/dev/null | awk '{print $2}')
    if [ "$STATUS" != "running" ]; then
        echo -e "│  $(err "Không running (status: $STATUS) — bỏ qua")"
        echo -e "└──"
        echo ""
        SKIPPED=$((SKIPPED + 1))
        return
    fi

    # Kiểm tra OS (chỉ support apt-based)
    local HAS_APT
    HAS_APT=$(pct exec "$CTID" -- bash -c "command -v apt-get && echo yes || echo no" 2>/dev/null || echo "no")
    if [[ "$HAS_APT" != *"yes"* ]]; then
        echo -e "│  $(err "Không phải apt-based OS — bỏ qua")"
        echo -e "└──"
        echo ""
        SKIPPED=$((SKIPPED + 1))
        return
    fi

    if $DRY_RUN; then
        dim "DRY-RUN: sẽ install ${#FONT_PACKAGES[@]} font packages"
        echo -e "└──"
        echo ""
        return
    fi

    # apt-get update
    echo -e "│  $(log "apt-get update...")"
    if ! pct exec "$CTID" -- bash -c "apt-get update -qq" 2>&1 | sed 's/^/│    /'; then
        echo -e "│  $(err "apt-get update thất bại")"
        echo -e "└──"
        echo ""
        FAILED=$((FAILED + 1))
        return
    fi

    # apt-get install
    echo -e "│  $(log "Installing ${#FONT_PACKAGES[@]} font packages...")"
    if pct exec "$CTID" -- bash -c "
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $PACKAGES_STR
    " 2>&1 | sed 's/^/│    /'; then
        # fc-cache
        echo -e "│  $(log "Rebuilding font cache...")"
        pct exec "$CTID" -- bash -c "fc-cache -fv" 2>&1 | grep -E "^/|succeeded" | head -5 | sed 's/^/│    /'
        echo -e "│  $(ok "Done!")"
        SUCCESS=$((SUCCESS + 1))
    else
        echo -e "│  $(err "Install thất bại")"
        FAILED=$((FAILED + 1))
    fi

    echo -e "└──"
    echo ""
}

# --- Main loop ---
for CTID in "${CONTAINER_IDS[@]}"; do
    install_fonts_on "$CTID"
done

# --- Final report ---
echo -e "${BOLD}═══════════════════════════════════════${R}"
echo -e " Kết quả:"
echo -e "   ${GREEN}✔ Thành công : $SUCCESS${R}"
[ $FAILED  -gt 0 ] && echo -e "   ${RED}✘ Thất bại   : $FAILED${R}"
[ $SKIPPED -gt 0 ] && echo -e "   ${YELLOW}⚠ Bỏ qua     : $SKIPPED${R}"
echo -e "${BOLD}═══════════════════════════════════════${R}"
echo ""
