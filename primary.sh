#!/bin/bash

# Colors for output
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
NC="\e[0m"

# Configuration paths
NAMED_CONF="/etc/named.conf"
NAMED_ZONES="/etc/named.rfc1912.zones"
ZONE_DIR="/var/named"
BACKUP_DIR="/var/backup/dns"
GROUP="named"

# ========== Logging helpers ==========
log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${CYAN}[SUCCESS]${NC} $1"; }

pause() { read -p "Nhấn Enter để tiếp tục..."; }
firewall-cmd --permanent --zone=public --add-service=dns > /dev/null 2>&1
firewall-cmd --reload > /dev/null 2>&1
check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "Script phải chạy với quyền root."
    exit 1
  fi
}

# ========== Validate ==========
validate_ip() {
  local ip=$1
  local stat=1

  if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    IFS='.' read -r -a octets <<< "$ip"
    if [[ ${octets[0]} -le 255 && ${octets[1]} -le 255 && ${octets[2]} -le 255 && ${octets[3]} -le 255 ]]; then
      stat=0
    fi
  fi
  return $stat
}

# ========== Cài đặt DNS ==========
install_bind() {
    # Check if already installed
    if rpm -q bind &>/dev/null && rpm -q bind-utils &>/dev/null; then
        return 0
    fi

    log "Đang cài đặt BIND packages..."

    # Check if network is available
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        error "Không có kết nối internet. Vui lòng kiểm tra kết nối mạng."
        return 1
    fi

    # Check yum installed
    if ! command -v yum &> /dev/null; then
        error "Không tìm thấy yum. Script chỉ hỗ trợ CentOS/RHEL."
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

configure_ip_and_named() {
    log "Cấu hình IP tĩnh và tạo named.conf..."

    # Cài ipcalc nếu chưa có
    if ! command -v ipcalc >/dev/null 2>&1; then
        log "ipcalc chưa cài, đang cài đặt..."
        sudo yum install ipcalc -y >/dev/null 2>&1
        log "ipcalc đã cài xong."
    fi

    # Xác định interface và connection
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    INTERFACE=${INTERFACE:-ens33}
    # log "Interface hiện tại: $INTERFACE"

    CON_NAME=$(nmcli -t -f NAME,DEVICE connection show | grep "$INTERFACE" | cut -d: -f1)
    if [ -z "$CON_NAME" ]; then
        log "Không tìm thấy connection cho interface $INTERFACE"
        return 1
    fi
    # log "Connection hiện tại: $CON_NAME"

    # Nhập thông tin IP tĩnh
    read -p "Nhập địa chỉ IP tĩnh (mặc định: 192.168.232.10): " IP_ADDR
    IP_ADDR=${IP_ADDR:-192.168.232.10}

    read -p "Nhập Subnet Mask (mặc định: 255.255.255.0): " NETMASK
    NETMASK=${NETMASK:-255.255.255.0}

    read -p "Nhập Gateway (mặc định: 192.168.232.2): " GATEWAY
    GATEWAY=${GATEWAY:-192.168.232.2}

    PREFIX=$(ipcalc -p $IP_ADDR $NETMASK | cut -d= -f2)
    NETWORK=$(ipcalc -n $IP_ADDR $NETMASK | cut -d= -f2)

    # Áp dụng IP tĩnh
    sudo nmcli con mod "$CON_NAME" ipv4.addresses "$IP_ADDR/$PREFIX"
    sudo nmcli con mod "$CON_NAME" ipv4.gateway "$GATEWAY"
    sudo nmcli con mod "$CON_NAME" ipv4.dns "$IP_ADDR"
    sudo nmcli con mod "$CON_NAME" ipv4.method manual
    sudo nmcli con up "$CON_NAME"
    log "IP tĩnh đã được áp dụng: $IP_ADDR/$PREFIX, Gateway: $GATEWAY"

    # Tạo named.conf
    log "Tạo file /etc/named.conf ..."
    sudo tee /etc/named.conf > /dev/null <<EOF
options {
    directory "/var/named";
    listen-on port 53 { 127.0.0.1; $IP_ADDR; };
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
    log "named.conf đã được tạo xong với listen-on: 127.0.0.1, $IP_ADDR và allow-query: $NETWORK/$PREFIX"
}


setup_dns_server() {
	log "Setup DNS server"
	
	# Install BIND
	install_bind || { error "Dừng cài đặt do BIND thất bại."; return 1; }
	
	configure_ip_and_named
	
	# Start and enable named service
	sudo systemctl enable named
	sudo systemctl start named
	
	success "Cài đặt DNS server hoàn tất! Bạn có thể tiến hành tạo zone."
  echo
  read -p "Nhấn Enter để tiếp tục..."
}

# ========== Zone & Record ==========
create_forward_zone() {
  echo "=== Tạo Forward Zone mới ==="
  while true; do
    read -p "Nhập domain (vd: example.com): " DOMAIN
    [ -z "$DOMAIN" ] && echo "Domain không được rỗng." && continue
    if grep -q "zone \"$DOMAIN\"" "$NAMED_ZONES"; then
      echo "Zone $DOMAIN đã tồn tại, vui lòng nhập domain khác."
    else
      break
    fi
  done

  read -p "Nhập IP cho ns1.${DOMAIN}: " NS_IP
  while ! validate_ip "$NS_IP"; do
    error "IP không hợp lệ, vui lòng nhập lại!"
    read -p "Nhập IP cho ns1.${DOMAIN}: " NS_IP
  done

  FORWARD_ZONE_FILE="$ZONE_DIR/forward.${DOMAIN}"

  SERIAL=$(date +%Y%m%d)01
  cat <<EOF >"$FORWARD_ZONE_FILE"
\$TTL 86400
@   IN  SOA ns1.$DOMAIN. admin.$DOMAIN. (
        $SERIAL ; Serial
        3600    ; Refresh
        1800    ; Retry
        1209600 ; Expire
        86400 ) ; Minimum TTL

    IN  NS  ns1.$DOMAIN.
ns1 IN  A   $NS_IP
@   IN  A   $NS_IP
EOF

  cat <<EOF >>"$NAMED_ZONES"

zone "$DOMAIN" IN {
    type master;
    file "$FORWARD_ZONE_FILE";
};
EOF

  chown root:$GROUP "$FORWARD_ZONE_FILE"
  chmod 640 "$FORWARD_ZONE_FILE"

  systemctl restart named
  success "Zone $DOMAIN đã được tạo và dịch vụ named đã restart."
  pause
}

create_reverse_zone_if_needed() {
  local IP=$1
  local DOMAIN=$2
  local HOST=$3

  IFS='.' read -r o1 o2 o3 o4 <<< "$IP"
  local REV_ZONE="${o3}.${o2}.${o1}.in-addr.arpa"
  local REV_FILE="$ZONE_DIR/reverse.${o3}.${o2}.${o1}.in-addr.arpa"

  # Nếu reverse zone chưa tồn tại thì tạo
  if ! grep -q "zone \"$REV_ZONE\"" "$NAMED_ZONES"; then
    SERIAL=$(date +%Y%m%d)01
    cat <<EOF > "$REV_FILE"
\$TTL 86400
@   IN  SOA ns1.$DOMAIN. admin.$DOMAIN. (
        $SERIAL ; Serial
        3600    ; Refresh
        1800    ; Retry
        1209600 ; Expire
        86400 ) ; Minimum TTL

    IN  NS  ns1.$DOMAIN.
EOF

    # Thêm vào named.rfc1912.zones
    cat <<EOF >> "$NAMED_ZONES"

zone "$REV_ZONE" IN {
    type master;
    file "$REV_FILE";
};
EOF

    chown root:$GROUP "$REV_FILE"
    chmod 640 "$REV_FILE"
    success "Reverse zone $REV_ZONE đã được tạo."
  fi

  # Thêm PTR record
  local PTR_NAME=${HOST:-$DOMAIN}
  # Kiểm tra xem PTR đã tồn tại chưa
  if ! grep -qE "^[[:space:]]*$o4[[:space:]]+IN[[:space:]]+PTR[[:space:]]+$PTR_NAME\.$DOMAIN\." "$REV_FILE"; then
      echo "$o4   IN PTR $PTR_NAME.$DOMAIN." >> "$REV_FILE"
      success "PTR record $IP → $PTR_NAME.$DOMAIN đã được thêm."
  fi

  # Reload reverse zone
  rndc reload $REV_ZONE &>/dev/null || rndc reload
}


add_dns_record() {
  echo "=== Thêm DNS Record ==="

  FORWARD_ZONES=()
  while IFS= read -r line; do
      if [[ $line =~ zone\ \"([^\"]+)\" ]]; then
          ZONE_NAME="${BASH_REMATCH[1]}"
          if [[ $ZONE_NAME != *"in-addr.arpa" ]]; then
              FORWARD_ZONES+=("$ZONE_NAME")
          fi
      fi
  done < "$NAMED_ZONES"

  if [ ${#FORWARD_ZONES[@]} -eq 0 ]; then
      echo " Không có Forward Zone nào."
      pause
      return
  fi

  echo "Danh sách Forward Zones:"
  for i in "${!FORWARD_ZONES[@]}"; do
      echo "  $((i+1)). ${FORWARD_ZONES[$i]}"
  done

  echo
  read -p "Chọn số thứ tự Zone để thêm record: " ZONE_INDEX
  if ! [[ $ZONE_INDEX =~ ^[0-9]+$ ]] || [ "$ZONE_INDEX" -lt 1 ] || [ "$ZONE_INDEX" -gt ${#FORWARD_ZONES[@]} ]; then
      error "Lựa chọn không hợp lệ!"
      pause
      return
  fi

  DOMAIN="${FORWARD_ZONES[$((ZONE_INDEX-1))]}"
  FORWARD_ZONE_FILE="$ZONE_DIR/forward.${DOMAIN}"

  echo "Bạn đang thêm record cho zone: $DOMAIN"
  read -p "Nhập hostname (vd: www, để trống = domain chính): " HOST
  read -p "Nhập IP cho ${HOST:+$HOST.}$DOMAIN: " IP
  while ! validate_ip "$IP"; do
    error "IP không hợp lệ, vui lòng nhập lại!"
    read -p "Nhập IP cho ${HOST:+$HOST.}$DOMAIN: " IP
  done

  # Thêm record A vào forward zone
  if [ -z "$HOST" ]; then
      echo "@   IN  A   $IP" >> "$FORWARD_ZONE_FILE"
      echo " Đã thêm record: $DOMAIN → $IP"
  else
      echo "${HOST}   IN  A   $IP" >> "$FORWARD_ZONE_FILE"
      echo " Đã thêm record: ${HOST}.${DOMAIN} → $IP"
  fi

  # Kiểm tra & gợi ý tạo reverse zone
  create_reverse_zone_if_needed "$IP" "$DOMAIN" "$HOST"
# Reload forward zone luôn
  rndc reload $DOMAIN



  pause
}


list_zones() {
    clear
    echo "=== Danh sách Zones ==="

    FORWARD_ZONES=()
    REVERSE_ZONES=()

    while IFS= read -r line; do
        if [[ $line =~ zone\ \"([^\"]+)\" ]]; then
            ZONE_NAME="${BASH_REMATCH[1]}"
            if [[ $ZONE_NAME == *"in-addr.arpa" ]]; then
                REVERSE_ZONES+=("$ZONE_NAME")
            else
                FORWARD_ZONES+=("$ZONE_NAME")
            fi
        fi
    done < "$NAMED_ZONES"

    echo "Forward Zones:"
    if [ ${#FORWARD_ZONES[@]} -eq 0 ]; then
        echo "  (Không có Forward Zone nào)"
    else
        for z in "${FORWARD_ZONES[@]}"; do
            echo "  - $z"
        done
    fi

    echo
    echo "Reverse Zones:"
    if [ ${#REVERSE_ZONES[@]} -eq 0 ]; then
        echo "  (Không có Reverse Zone nào)"
    else
        for z in "${REVERSE_ZONES[@]}"; do
            echo "  - $z"
        done
    fi

    echo
    read -p "Nhấn Enter để tiếp tục..."
}

list_records() {
  echo "=== Xem records của Zone ==="

  FORWARD_ZONES=()
  while IFS= read -r line; do
      if [[ $line =~ zone\ \"([^\"]+)\" ]]; then
          ZONE_NAME="${BASH_REMATCH[1]}"
          if [[ $ZONE_NAME != *"in-addr.arpa" ]]; then
              FORWARD_ZONES+=("$ZONE_NAME")
          fi
      fi
  done < "$NAMED_ZONES"

  if [ ${#FORWARD_ZONES[@]} -eq 0 ]; then
      echo "Không có Forward Zone nào."
      pause
      return
  fi

  echo "Danh sách Forward Zones:"
  for i in "${!FORWARD_ZONES[@]}"; do
      echo "  $((i+1)). ${FORWARD_ZONES[$i]}"
  done

  echo
  read -p "Chọn số thứ tự Zone để xem records: " ZONE_INDEX
  if ! [[ $ZONE_INDEX =~ ^[0-9]+$ ]] || [ "$ZONE_INDEX" -lt 1 ] || [ "$ZONE_INDEX" -gt ${#FORWARD_ZONES[@]} ]; then
      error "Lựa chọn không hợp lệ!"
      pause
      return
  fi

  DOMAIN="${FORWARD_ZONES[$((ZONE_INDEX-1))]}"
  FORWARD_ZONE_FILE="$ZONE_DIR/forward.${DOMAIN}"

  echo
  echo "=== Records trong zone $DOMAIN ==="
  if [ -f "$FORWARD_ZONE_FILE" ]; then
      grep -E "IN[[:space:]]+(A|CNAME|MX)" "$FORWARD_ZONE_FILE" | while read -r HOST TYPE VALUE; do
          case "$HOST" in
              "@") HOSTNAME="$DOMAIN" ;;
              *)   HOSTNAME="$HOST.$DOMAIN" ;;
          esac
          echo " $HOSTNAME → $VALUE"
      done
  else
      error "Không tìm thấy file zone: $FORWARD_ZONE_FILE"
  fi

  pause
}

configure_slave_dns() {
    log "Cấu hình Slave DNS cho Forward Zone..."
    # ============================================================
    read -p "Nhập tên zone (ví dụ: edu.vn): " ZONENAME
    ZONEFILE="/var/named/forward.${ZONENAME}"
    NAMEDCONF="/etc/named.conf"

    if [ ! -f "$ZONEFILE" ]; then
        error "Zone file $ZONEFILE không tồn tại!"
        return 1
    fi

    read -p "Nhập hostname Secondary (ví dụ: secondary.edu.vn): " SECHOST
    read -p "Nhập IP Secondary (ví dụ: 192.168.232.20): " SECIP

    # Đảm bảo SECHOST có dấu chấm cuối
    [[ "$SECHOST" != *"." ]] && SECHOST="${SECHOST}."

    # Thêm NS nếu chưa tồn tại
    if ! grep -q "$SECHOST" "$ZONEFILE"; then
        echo "@   IN NS $SECHOST" >> "$ZONEFILE"
        success "Đã thêm NS record cho $SECHOST"
    else
        warn "NS record $SECHOST đã tồn tại"
    fi

    # Thêm A record nếu chưa tồn tại
    HOSTNAME_ONLY=$(echo "$SECHOST" | sed "s/.$ZONENAME.//")
    if ! grep -q "^$HOSTNAME_ONLY\s\+IN\s\+A\s\+$SECIP" "$ZONEFILE"; then
        echo "$HOSTNAME_ONLY   IN A $SECIP" >> "$ZONEFILE"
        success "Đã thêm A record cho $HOSTNAME_ONLY -> $SECIP"
    else
        warn "A record cho $HOSTNAME_ONLY -> $SECIP đã tồn tại"
    fi
    
    # ====== NEW: Thêm PTR vào reverse zone ======
    create_reverse_zone_if_needed "$SECIP" "$ZONENAME" "$HOSTNAME_ONLY"

    # Cập nhật allow-transfer trong named.conf
    if ! grep -A5 "options {" "$NAMEDCONF" | grep -q "allow-transfer"; then
        sed -i "/options {/a\    allow-transfer { $SECIP; };" "$NAMEDCONF"
        success "Đã thêm allow-transfer { $SECIP; } vào $NAMEDCONF"
    else
        warn "options đã có allow-transfer"
    fi

    # Tăng serial an toàn
    CUR_SERIAL=$(grep -A1 'SOA' "$ZONEFILE" | grep -oE '[0-9]{10}')
    if [ -n "$CUR_SERIAL" ]; then
        NEW_SERIAL=$((CUR_SERIAL + 1))
        sed -i "s/$CUR_SERIAL/$NEW_SERIAL/" "$ZONEFILE"
        success "Serial tăng từ $CUR_SERIAL -> $NEW_SERIAL"
    else
        warn "Không tìm thấy serial, vui lòng kiểm tra SOA block"
    fi

    # Kiểm tra zone file
    log "Kiểm tra zone file..."
    named-checkzone "$ZONENAME" "$ZONEFILE"
    if [ $? -eq 0 ]; then
        success "Zone file hợp lệ. Restart named..."
        systemctl restart named && success "Dịch vụ named đã restart"
    else
        error "Zone file có vấn đề, vui lòng kiểm tra!"
    fi

    echo
    read -p "Nhấn Enter để tiếp tục..."
}




# ========== Menu ==========
show_menu() {
  clear
  echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║                    DNS SERVER MANAGEMENT                  ║${NC}"
  echo -e "${CYAN}╠═══════════════════════════════════════════════════════════╣${NC}"
  echo -e "${CYAN}║${NC} 1.  Cài đặt và cấu hình DNS Server                        ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC} 2.  Tạo Forward Zone mới                                  ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC} 3.  Thêm DNS Record                                       ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC} 4.  Xem danh sách Zones                                   ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC} 5.  Xem Records của Zone                                  ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC} 6.  Cấu hình IP Secondary                                 ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC} 7.  Kiểm tra trạng thái DNS                               ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC} 0.  Thoát                                                 ${CYAN}║${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
}

main_menu() {
  while true; do
    show_menu
    read -p "Chọn chức năng (0-9): " choice
    case $choice in
      1) setup_dns_server ;;
      2) create_forward_zone ;;
      3) add_dns_record ;;
      4) list_zones ;;
      5) list_records ;;
      6) configure_slave_dns ;;
      7) systemctl status named --no-pager ; pause ;;
      0) echo -e "${GREEN}Cảm ơn bạn đã sử dụng DNS Management Tool!${NC}"; exit 0 ;;
      *) error "Lựa chọn không hợp lệ!"; pause ;;
    esac
  done
}

# ========== Main ==========
check_root
main_menu
