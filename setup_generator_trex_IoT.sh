#!/usr/bin/env bash
set -Eeuo pipefail

TREX_BASE_URL="https://trex-tgn.cisco.com/trex/release"
TREX_INSTALL_ROOT="/opt"
TREX_CFG_FILE="/etc/trex_cfg.yaml"
DEFAULT_GEN_COUNT=100
DEFAULT_DST_IP="192.168.1.100"
DEFAULT_COAP_PAYLOAD='\\x40\\x01\\x12\\x34\\xbb\\x74\\x65\\x6d\\x70\\x3d\\x32\\x32'
MODE="lab"
TREX_VERSION=""
TREX_ARCHIVE_URL=""
TREX_DIR=""
ALLOW_INSECURE_TREX_DOWNLOAD="ask"

SUPPORTED_TREX_DRIVERS_REGEX='^(ixgbe|i40e|ice|igb|mlx5_core|mlx4_core|bnxt_en|enic|vfio-pci|uio_pci_generic|igc)$'

log() { echo -e "\n[+] $*"; }
warn() { echo -e "[!] $*"; }
die() { echo -e "[x] $*" >&2; exit 1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запусти скрипт через sudo или от root"
}

install_base_packages() {
  log "Устанавливаю базовые зависимости"
  apt update
  apt install -y ca-certificates curl python3 python3-pip python3-scapy tcpdump wget tar iproute2 ethtool pciutils lshw
  update-ca-certificates || true
}

ask_insecure_download_permission() {
  local ans
  if [[ "$ALLOW_INSECURE_TREX_DOWNLOAD" == "always" ]]; then
    return 0
  fi
  if [[ "$ALLOW_INSECURE_TREX_DOWNLOAD" == "never" ]]; then
    return 1
  fi

  warn "У сервера TRex/Cisco бывают проблемы с TLS-цепочкой, из-за чего curl/wget не могут проверить сертификат"
  read -r -p "Разрешить fallback-загрузку без проверки сертификата только для trex-tgn.cisco.com? [y/N] " ans
  [[ "${ans,,}" =~ ^y(es)?$ ]]
}

http_get_text() {
  local url="$1"
  if curl -fsSL "$url" 2>/dev/null; then
    return 0
  fi

  warn "curl не смог получить $url по HTTPS с проверкой сертификата"
  if wget -qO- "$url" 2>/dev/null; then
    return 0
  fi

  if ask_insecure_download_permission; then
    warn "Пробую небезопасный fallback для $url"
    wget --no-check-certificate -qO- "$url"
    return 0
  fi

  return 1
}

get_latest_trex_version() {
  local latest_url version
  latest_url=$(http_get_text "$TREX_BASE_URL/latest" | tr -d '\r\n') || return 1
  version=$(basename "$latest_url")
  version=${version%.tar.gz}
  [[ -n "$version" ]] || return 1
  echo "$version"
}

pick_trex_version() {
  local detected chosen
  if detected=$(get_latest_trex_version); then
    echo "Найдена актуальная версия TRex: $detected"
    read -r -p "Использовать её? [Y/n/custom] " chosen
    case "${chosen,,}" in
      ""|y|yes) TREX_VERSION="$detected" ;;
      n|no|custom|c) read -r -p "Введи нужную версию вручную (например v3.08): " TREX_VERSION ;;
      *) warn "Непонятный ответ, беру автоопределённую версию: $detected"; TREX_VERSION="$detected" ;;
    esac
  else
    warn "Не удалось автоматически определить последнюю версию TRex"
    read -r -p "Введи версию вручную (например v3.08): " TREX_VERSION
  fi

  TREX_ARCHIVE_URL="$TREX_BASE_URL/${TREX_VERSION}.tar.gz"
  TREX_DIR="$TREX_INSTALL_ROOT/trex/${TREX_VERSION}"
}

choose_mode() {
  echo
  echo "Выбери режим настройки TRex:"
  echo "  1) lab     - упрощённый лабораторный режим (Linux IF, dummy допустим)"
  echo "  2) prod    - боевой DPDK-ориентированный режим (PCI, проверка NIC, расширенный trex_cfg.yaml)"
  read -r -p "Выбор [1/2, по умолчанию 1]: " mode_choice
  case "${mode_choice:-1}" in
    1) MODE="lab" ;;
    2) MODE="prod" ;;
    *) warn "Некорректный выбор, использую lab"; MODE="lab" ;;
  esac
}

list_interfaces() {
  ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'
}

get_iface_ipv4() {
  ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | paste -sd ',' -
}

get_iface_driver() {
  ethtool -i "$1" 2>/dev/null | awk -F': ' '/driver:/ {print $2; exit}'
}

get_iface_bus_info() {
  ethtool -i "$1" 2>/dev/null | awk -F': ' '/bus-info:/ {print $2; exit}'
}

iface_is_physical() {
  [[ -e "/sys/class/net/$1/device" ]]
}

show_interfaces_detailed() {
  local iface state mac ipv4 driver pci
  printf "\nДоступные интерфейсы:\n"
  printf "%-4s %-14s %-10s %-20s %-18s %-12s %-12s\n" "No." "Interface" "State" "MAC" "IPv4" "Driver" "PCI"
  printf "%-4s %-14s %-10s %-20s %-18s %-12s %-12s\n" "---" "---------" "-----" "---" "----" "------" "---"
  local i=1
  while read -r iface; do
    state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo unknown)
    mac=$(cat "/sys/class/net/$iface/address" 2>/dev/null || echo unknown)
    ipv4=$(get_iface_ipv4 "$iface")
    [[ -n "$ipv4" ]] || ipv4="-"
    driver=$(get_iface_driver "$iface")
    [[ -n "$driver" ]] || driver="-"
    pci=$(get_iface_bus_info "$iface")
    [[ -n "$pci" ]] || pci="-"
    printf "%-4s %-14s %-10s %-20s %-18s %-12s %-12s\n" "$i" "$iface" "$state" "$mac" "$ipv4" "$driver" "$pci"
    IFACE_LIST[$i]="$iface"
    ((i++))
  done < <(list_interfaces)
  [[ ${#IFACE_LIST[@]} -gt 0 ]] || die "Не найдено сетевых интерфейсов"
}

choose_interfaces() {
  declare -gA IFACE_LIST=()
  show_interfaces_detailed
  echo
  read -r -p "Выбери основной интерфейс по номеру: " idx1
  [[ -n "${IFACE_LIST[$idx1]:-}" ]] || die "Некорректный выбор основного интерфейса"
  PRIMARY_IFACE="${IFACE_LIST[$idx1]}"

  read -r -p "Выбери второй интерфейс по номеру или Enter для dummy: " idx2
  if [[ -n "$idx2" ]]; then
    [[ -n "${IFACE_LIST[$idx2]:-}" ]] || die "Некорректный выбор второго интерфейса"
    SECONDARY_IFACE="${IFACE_LIST[$idx2]}"
  else
    SECONDARY_IFACE="dummy"
  fi

  PRIMARY_MAC=$(cat "/sys/class/net/$PRIMARY_IFACE/address")
  PRIMARY_PCI=$(get_iface_bus_info "$PRIMARY_IFACE")
  PRIMARY_DRIVER=$(get_iface_driver "$PRIMARY_IFACE")

  if [[ "$SECONDARY_IFACE" != "dummy" ]]; then
    SECONDARY_MAC=$(cat "/sys/class/net/$SECONDARY_IFACE/address")
    SECONDARY_PCI=$(get_iface_bus_info "$SECONDARY_IFACE")
    SECONDARY_DRIVER=$(get_iface_driver "$SECONDARY_IFACE")
  else
    SECONDARY_MAC="00:00:00:00:00:00"
    SECONDARY_PCI="dummy"
    SECONDARY_DRIVER="dummy"
  fi
}

validate_iface_for_trex() {
  local iface="$1" driver="$2" pci="$3"
  [[ "$iface" == "dummy" ]] && return 0

  iface_is_physical "$iface" || die "Интерфейс $iface не выглядит как физический NIC: нет /sys/class/net/$iface/device"
  [[ -n "$pci" && "$pci" != "-" ]] || die "Для интерфейса $iface не найден PCI bus-info; для боевого режима это обязательно"
  [[ -n "$driver" && "$driver" != "-" ]] || die "Для интерфейса $iface не найден driver через ethtool -i"

  if [[ ! "$driver" =~ $SUPPORTED_TREX_DRIVERS_REGEX ]]; then
    warn "Драйвер $driver для интерфейса $iface не входит в типичный список совместимых для TRex/DPDK"
    warn "Это не жёсткий запрет, но для prod-режима лучше использовать поддерживаемый NIC"
    if [[ "$MODE" == "prod" ]]; then
      read -r -p "Продолжить несмотря на предупреждение? [y/N] " ans
      [[ "${ans,,}" =~ ^y(es)?$ ]] || die "Остановлено из-за потенциально неподходящего интерфейса $iface"
    fi
  fi
}

validate_selected_interfaces() {
  log "Проверяю выбранные интерфейсы на пригодность для TRex"
  validate_iface_for_trex "$PRIMARY_IFACE" "$PRIMARY_DRIVER" "$PRIMARY_PCI"

  if [[ "$SECONDARY_IFACE" != "dummy" ]]; then
    validate_iface_for_trex "$SECONDARY_IFACE" "$SECONDARY_DRIVER" "$SECONDARY_PCI"
  elif [[ "$MODE" == "prod" ]]; then
    die "В боевом режиме второй интерфейс обязателен; dummy недопустим"
  fi

  if [[ "$MODE" == "prod" ]]; then
    [[ "$PRIMARY_IFACE" != "$SECONDARY_IFACE" ]] || die "Для prod-режима нужны два разных интерфейса"
    [[ "$PRIMARY_PCI" != "$SECONDARY_PCI" ]] || die "Интерфейсы не должны ссылаться на один и тот же PCI device"
  fi
}

prepare_interfaces() {
  for iface in "$PRIMARY_IFACE"; do
    log "Подготавливаю интерфейс $iface"
    ip link set "$iface" up
    ip link set "$iface" promisc on
  done

  if [[ "$SECONDARY_IFACE" != "dummy" ]]; then
    log "Подготавливаю интерфейс $SECONDARY_IFACE"
    ip link set "$SECONDARY_IFACE" up
    ip link set "$SECONDARY_IFACE" promisc on
  fi
}

download_trex_archive() {
  local dst="$1"

  if curl -fL "$TREX_ARCHIVE_URL" -o "$dst"; then
    return 0
  fi

  warn "curl не смог скачать архив TRex с проверкой сертификата"
  if wget -O "$dst" "$TREX_ARCHIVE_URL"; then
    return 0
  fi

  if ask_insecure_download_permission; then
    warn "Пробую скачать TRex без проверки сертификата (--no-check-certificate)"
    wget --no-check-certificate -O "$dst" "$TREX_ARCHIVE_URL" && return 0
  fi

  return 1
}

install_trex() {
  log "Скачиваю TRex $TREX_VERSION"
  mkdir -p "$TREX_DIR"
  cd "$TREX_DIR"
  rm -f trex.tar.gz

  download_trex_archive trex.tar.gz || die "Не удалось скачать $TREX_ARCHIVE_URL"

  tar -xzvf trex.tar.gz --strip-components=1
  chmod -R 755 "$TREX_DIR"
  ln -sfn "$TREX_DIR" /opt/trex-current
  log "TRex установлен в $TREX_DIR"
}

cpu_thread_list() {
  local total
  total=$(nproc)
  if (( total <= 4 )); then
    echo "[2]"
  elif (( total <= 8 )); then
    echo "[2,3,4]"
  else
    seq 2 $(( total - 1 )) | paste -sd ',' - | sed 's/^/[/' | sed 's/$/]/'
  fi
}

create_trex_cfg_lab() {
  log "Создаю лабораторную конфигурацию $TREX_CFG_FILE"
  cat > "$TREX_CFG_FILE" <<EOF_CFG
- port_limit: 2
  version: 2
  interfaces: ["$PRIMARY_IFACE", "$SECONDARY_IFACE"]
  port_info:
    - dest_mac: "ff:ff:ff:ff:ff:ff"
      src_mac: "$PRIMARY_MAC"
    - dest_mac: "ff:ff:ff:ff:ff:ff"
      src_mac: "$SECONDARY_MAC"
EOF_CFG
}

create_trex_cfg_prod() {
  local threads
  threads=$(cpu_thread_list)
  log "Создаю боевую DPDK-ориентированную конфигурацию $TREX_CFG_FILE"

  read -r -p "Введи dest_mac для PRIMARY_IFACE ($PRIMARY_IFACE), подключённого к DUT: " PRIMARY_DEST_MAC
  read -r -p "Введи dest_mac для SECONDARY_IFACE ($SECONDARY_IFACE), подключённого к DUT: " SECONDARY_DEST_MAC
  read -r -p "NUMA socket для dual_if [0]: " NUMA_SOCKET
  NUMA_SOCKET=${NUMA_SOCKET:-0}

  cat > "$TREX_CFG_FILE" <<EOF_CFG
### Config file generated by setup_diploma_improved.sh ###
- version: 2
  interfaces: ["$PRIMARY_PCI", "$SECONDARY_PCI"]
  prefix: trex
  limit_memory: 4096
  port_info:
    - dest_mac: "$PRIMARY_DEST_MAC"
      src_mac: "$PRIMARY_MAC"
    - dest_mac: "$SECONDARY_DEST_MAC"
      src_mac: "$SECONDARY_MAC"
  platform:
    master_thread_id: 0
    latency_thread_id: 1
    dual_if:
      - socket: $NUMA_SOCKET
        threads: $threads
EOF_CFG
}

create_trex_cfg() {
  if [[ "$MODE" == "prod" ]]; then
    create_trex_cfg_prod
  else
    create_trex_cfg_lab
  fi
}

create_generator_script() {
  local current_dir gen_file
  current_dir=$(pwd)
  gen_file="$current_dir/gen_iot_v2.py"

  log "Создаю генератор IoT-трафика: $gen_file"
  cat > "$gen_file" <<EOF_PY
from scapy.all import Ether, IP, UDP, Raw, wrpcap

pkts = []
print("Генерация ${DEFAULT_GEN_COUNT} пакетов CoAP для ${DEFAULT_GEN_COUNT} датчиков...")

for i in range(1, ${DEFAULT_GEN_COUNT} + 1):
    pkt = (
        Ether(src="${PRIMARY_MAC}", dst="ff:ff:ff:ff:ff:ff") /
        IP(src=f"10.0.0.{i}", dst="${DEFAULT_DST_IP}") /
        UDP(sport=5683, dport=5683) /
        Raw(load=b"${DEFAULT_COAP_PAYLOAD}")
    )
    pkts.append(pkt)

wrpcap('/tmp/iot_traffic_v2.pcap', pkts)
print("Файл сохранён: /tmp/iot_traffic_v2.pcap")
EOF_PY

  if [[ -n "${SUDO_USER:-}" ]]; then
    chown "$SUDO_USER:$SUDO_USER" "$gen_file"
  fi
}

print_summary() {
  cat <<EOF_SUMMARY

=======================================================
УСТАНОВКА ЗАВЕРШЕНА
Mode         : $MODE
TRex version : $TREX_VERSION
TRex path    : $TREX_DIR
Primary iface: $PRIMARY_IFACE | driver=$PRIMARY_DRIVER | pci=$PRIMARY_PCI | mac=$PRIMARY_MAC
Secondary    : $SECONDARY_IFACE | driver=$SECONDARY_DRIVER | pci=$SECONDARY_PCI | mac=$SECONDARY_MAC
TRex config  : $TREX_CFG_FILE
Generator    : $(pwd)/gen_iot_v2.py
PCAP output  : /tmp/iot_traffic_v2.pcap
=======================================================

Полезные команды:
  python3 gen_iot_v2.py
  tcpdump -nn -r /tmp/iot_traffic_v2.pcap
  /opt/trex-current/t-rex-64 -i
EOF_SUMMARY

  if [[ "$MODE" == "prod" ]]; then
    echo "Для prod-режима проверь соответствие PCI, NUMA и MAC адресов в $TREX_CFG_FILE перед запуском TRex."
  fi
}

main() {
  require_root
  install_base_packages
  choose_mode
  pick_trex_version
  choose_interfaces
  validate_selected_interfaces
  prepare_interfaces
  install_trex
  create_trex_cfg
  create_generator_script
  print_summary
}

main "$@"
