#!/bin/bash
# Script cấu hình Secondary DNS Server tự động
# Áp dụng cho CentOS/RHEL (BIND)

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Vui lòng chạy script với quyền root"
    exit 1
fi

NAMEDCONF="/etc/named.conf"
ZONECONF="/etc/named.rfc1912.zones"
SLAVE_DIR="/var/named/slaves"

# Colors for output
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
NC="\e[0m"

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${CYAN}[SUCCESS]${NC} $1"; }

install_bind() {
    
    # Check if already installed
    if rpm -q bind &>/dev/null && rpm -q bind-utils &>/dev/null; then
        return 0
    fi

    log "Đang cài đặt BIND packages..."

    # Check if network is available
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        error "Không có kết nối internet. Vui lòng kiểm tra kết nối mạng."
        echo
        read -p "Nhấn Enter để tiếp tục..."
        return 1
    fi

    # Check yum installed
    if ! command -v yum &> /dev/null; then
        error "Không tìm thấy yum. Script chỉ hỗ trợ CentOS/RHEL."
        echo
        read -p "Nhấn Enter để tiếp tục..."
        return 1
    fi

    # Install bind packages
    if sudo yum install -y bind bind-utils >/dev/null 2>&1; then
        log "BIND packages đã được cài đặt thành công!"
    else
        error "Cài đặt BIND packages thất bại!"
        return 1
    fi
}

# ==================
configure_slave_ip() {
    log "Cấu hình IP tĩnh cho Slave DNS..."

    install_bind 

    # Cài ipcalc nếu chưa có
    if ! command -v ipcalc >/dev/null 2>&1; then
        log "ipcalc chưa cài, đang cài đặt..."
        sudo yum install ipcalc -y >/dev/null 2>&1
        log "ipcalc đã cài xong."
    fi


    # Xác định interface
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -z "$INTERFACE" ]; then
        INTERFACE="ens33"
    fi
    # log "Interface hiện tại: $INTERFACE"

    # Xác định connection name
    CON_NAME=$(nmcli -t -f NAME,DEVICE connection show | grep "$INTERFACE" | cut -d: -f1)
    if [ -z "$CON_NAME" ]; then
        error "Không tìm thấy connection cho interface $INTERFACE"
        return 1
    fi
    # log "Connection hiện tại: $CON_NAME"

    # Nhập thông tin
    echo -n "Nhập IP tĩnh cho Slave (mặc định: 192.168.232.20): "
    read SLAVE_IP
    SLAVE_IP=${SLAVE_IP:-192.168.232.20}

    echo -n "Nhập Subnet Mask (mặc định: 255.255.255.0): "
    read NETMASK
    NETMASK=${NETMASK:-255.255.255.0}

    echo -n "Nhập Gateway (mặc định: 192.168.232.3): "
    read GATEWAY
    GATEWAY=${GATEWAY:-192.168.232.3}

    echo -n "Nhập IP Master DNS (mặc định: 192.168.232.10): "
    read MASTER_IP
    MASTER_IP=${MASTER_IP:-192.168.232.10}

    PREFIX=$(ipcalc -p $SLAVE_IP $NETMASK | cut -d= -f2)
    NETWORK=$(ipcalc -n $SLAVE_IP $NETMASK | cut -d= -f2)

    # Áp dụng cấu hình
    sudo nmcli con mod "$CON_NAME" ipv4.addresses "$SLAVE_IP/$PREFIX"
    sudo nmcli con mod "$CON_NAME" ipv4.gateway "$GATEWAY"
    sudo nmcli con mod "$CON_NAME" ipv4.dns "$SLAVE_IP"
    sudo nmcli con mod "$CON_NAME" ipv4.method manual

    sudo nmcli con up "$CON_NAME"

    log "Slave IP đã được áp dụng:"
    log "IP: $SLAVE_IP/$PREFIX | Gateway: $GATEWAY | DNS: $SLAVE_IP"


    # Tạo named.conf
    log "Tạo file /etc/named.conf ..."
    sudo tee /etc/named.conf > /dev/null <<EOF
options {
    directory "/var/named";
    listen-on port 53 { 127.0.0.1; $SLAVE_IP; };
    allow-query { 127.0.0.1; $NETWORK/$PREFIX; any; };
    recursion yes;
    dnssec-enable yes;
    dnssec-validation yes;
};

logging {
    channel default_debug {
        file "data/named.run";
        severity dynamic;
    };
};

zone "." IN {
    type hint;
    file "named.ca";
};

include "/etc/named.rfc1912.zones";
include "/etc/named.root.key";
EOF

    sudo chown root:named /etc/named.conf
    sudo chmod 644 /etc/named.conf
    log "named.conf đã được tạo xong với listen-on: 127.0.0.1, $SLAVE_IP và allow-query: $NETWORK/$PREFIX"

    echo
    read -p "Nhấn Enter để tiếp tục..."
}

configure_secondary_dns() {
    log "Cấu hình secondary DNS server..."

    # Nhập zone và IP Primary
    read -p "Nhập tên zone (vd: example.com): " ZONENAME
    read -p "Nhập IP Primary DNS: " MASTERIP

    # Backup file trước khi chỉnh sửa
    cp -p "$NAMEDCONF" "$NAMEDCONF.bak.$(date +%F_%T)"
    cp -p "$ZONECONF" "$ZONECONF.bak.$(date +%F_%T)"

    # Tạo thư mục slaves nếu chưa có
    if [ ! -d "$SLAVE_DIR" ]; then
        mkdir -p "$SLAVE_DIR"
        chown named:named "$SLAVE_DIR"
    fi

    log "Thêm cấu hình forward zone slave vào $ZONECONF ..."
    if ! grep -q "zone \"$ZONENAME\"" "$ZONECONF"; then
        cat >> "$ZONECONF" <<EOF

zone "$ZONENAME" IN {
    type slave;
    masters { $MASTERIP; };
    file "slaves/forward.$ZONENAME.zone";
};
EOF
        success "Zone $ZONENAME đã được thêm."
    else
        warn "Zone $ZONENAME đã tồn tại trong $ZONECONF, bỏ qua."
    fi

    # =================== BỔ SUNG REVERSE ZONE ===================
    REVERSEZONE=$(echo $MASTERIP | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')
    log "Thêm cấu hình reverse zone slave vào $ZONECONF ..."
    if ! grep -q "zone \"$REVERSEZONE\"" "$ZONECONF"; then
        cat >> "$ZONECONF" <<EOF

zone "$REVERSEZONE" IN {
    type slave;
    masters { $MASTERIP; };
    file "slaves/reverse.$REVERSEZONE.zone";
};
EOF
        success "Zone $REVERSEZONE đã được thêm."
    else
        warn "Zone $REVERSEZONE đã tồn tại trong $ZONECONF, bỏ qua."
    fi
    # ============================================================

    log "Cập nhật $NAMEDCONF ..."
    if ! grep -q "allow-transfer" "$NAMEDCONF"; then
        sed -i "/options {/a\    allow-transfer { $MASTERIP; };" "$NAMEDCONF"
        success "Đã thêm allow-transfer { $MASTERIP; }; vào options."
    fi

    log "Kiểm tra cấu hình ..."
    named-checkconf
    if [ $? -ne 0 ]; then
        error "named.conf có lỗi, hãy kiểm tra lại!"
        exit 1
    fi

    log "Restart dịch vụ named ..."
    systemctl restart named
    systemctl enable named
    systemctl status named --no-pager -l

    echo
    read -p "Nhấn Enter để tiếp tục..."
}

show_menu() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           DNS SERVER CONFIGURATION           ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC} 1. Cấu hình Slave IP                         ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} 2. Cấu hình Secondary DNS                    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} 0. Thoát                                     ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
    echo -n "Chọn một tùy chọn (0-2): "
}

while true; do
    show_menu
    read choice
    case $choice in
        1)
            configure_slave_ip
            ;;
        2)
            configure_secondary_dns
            ;;
        0)
            echo -e "${GREEN}Cảm ơn bạn đã sử dụng DNS Management Tool!${NC}"
            exit 0
            ;;
        *)
            error "Lựa chọn không hợp lệ!"
            pause
            ;;
    esac
done