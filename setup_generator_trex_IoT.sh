#!/bin/bash

set -u

if [[ $EUID -ne 0 ]]; then
   echo "Запусти через sudo!"
   exit 1
fi

LAUNCH_DIR=$(pwd)
TREX_DIR="/opt/trex"
SCENARIO_DIR="./scenarios"
BENCHMARK_DIR="./benchmarks"
TREX_CFG="/etc/trex_cfg.yaml"

START_MODE=""
MODE=""
INTERFACE1=""
INTERFACE2=""
MY_MAC1=""
MY_MAC2=""
PCI_ADDR1=""
PCI_ADDR2=""
TREX_VER_DIR=""
TREX_PATH=""

owner_user() {
    if [ -n "${SUDO_USER:-}" ]; then
        echo "$SUDO_USER"
    else
        logname 2>/dev/null || echo "root"
    fi
}

find_trex_path() {
    TREX_VER_DIR=$(find "$TREX_DIR" -maxdepth 1 -type d -name "v*" 2>/dev/null | sort -V | tail -n 1 | sed 's|.*/||')
    TREX_PATH="$TREX_DIR/$TREX_VER_DIR"

    if [ -z "$TREX_VER_DIR" ] || [ ! -d "$TREX_PATH" ]; then
        return 1
    fi

    return 0
}

require_trex_path() {
    if ! find_trex_path; then
        echo "TRex не найден в $TREX_DIR. Сначала поставь его через пункт установки."
        exit 1
    fi
}

install_trex() {
    echo "== Установка TRex =="
    apt update && apt install -y python3-scapy tcpdump wget tar ethtool unzip
    mkdir -p "$TREX_DIR" && cd "$TREX_DIR" || exit 1

    if [ -f "/tmp/latest.tar.gz" ]; then
        cp /tmp/latest.tar.gz .
    else
        wget --no-check-certificate https://trex-tgn.cisco.com/trex/release/latest -O latest.tar.gz
    fi
    tar -xzvf latest.tar.gz
    cd "$LAUNCH_DIR" || exit 1
}

find_dpdk_bind_tool() {
    find "$TREX_PATH" -type f \( -name "dpdk_nic_bind.py" -o -name "dpdk-devbind.py" \) 2>/dev/null | head -n 1
}

extract_pci_from_trex_cfg() {
    if [ ! -f "$TREX_CFG" ]; then
        return 0
    fi

    grep -oE '"[^"]+"' "$TREX_CFG" \
        | tr -d '"' \
        | grep -E '^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]$' \
        | sort -u
}

guess_kernel_driver() {
    local bind_tool="$1"
    local pci_addr="$2"
    local status_line
    local unused

    status_line=$(python3 "$bind_tool" -s 2>/dev/null | grep "$pci_addr" | head -n 1 || true)
    unused=$(echo "$status_line" | sed -n 's/.*unused=\([^ ]*\).*/\1/p' | tr ',' ' ')

    for driver in $unused; do
        case "$driver" in
            vfio-pci|igb_uio|uio_pci_generic)
                ;;
            *)
                echo "$driver"
                return 0
                ;;
        esac
    done

    return 1
}

release_dpdk_interfaces() {
    require_trex_path

    local bind_tool
    bind_tool=$(find_dpdk_bind_tool)
    if [ -z "$bind_tool" ]; then
        echo "Ошибка: не найден dpdk_nic_bind.py или dpdk-devbind.py внутри $TREX_PATH."
        exit 1
    fi

    echo "== Возврат интерфейсов DPDK -> Linux =="
    echo "bind tool: $bind_tool"
    echo "status:"
    python3 "$bind_tool" -s || true
    echo ""

    local pci_list
    pci_list=$(extract_pci_from_trex_cfg || true)

    if [ -z "$pci_list" ]; then
        echo "В $TREX_CFG нет PCI-адресов."
        read -r -p "Введи PCI-адреса интерфейсовPCI через пробел (например 0000:03:00.0 0000:04:00.0): " pci_list
    else
        echo "PCI из $TREX_CFG:"
        echo "$pci_list"
    fi

    if [ -z "$pci_list" ]; then
        echo "Нет PCI для отвязки."
        exit 0
    fi

    echo ""
    echo "TRex server должен быть остановлен. Проверьте перед продолжением."
    read -r -p "Вернуть интерфейсы в Linux-драйвер? [y/N]: " confirm
    confirm=$(echo "$confirm" | tr -d '\r' | xargs)
    case "$confirm" in
        y|Y|yes|YES|Yes|у|У|д|Д|да|ДА|Да)
            ;;
        *)
            echo "Отменено."
            exit 0
            ;;
    esac

    local pci_addr
    for pci_addr in $pci_list; do
        local auto_driver=""
        local target_driver=""

        auto_driver=$(guess_kernel_driver "$bind_tool" "$pci_addr" || true)
        if [ -n "$auto_driver" ]; then
            read -r -p "Драйвер для $pci_addr [Enter = $auto_driver]: " target_driver
            target_driver=${target_driver:-$auto_driver}
        else
            echo "Не обнаружен Linux-драйвер для $pci_addr."
            read -r -p "Укажите драйвер (ixgbe/i40e/e1000e/virtio-pci) или Enter чтобы пропустить: " target_driver
        fi

        if [ -z "$target_driver" ]; then
            echo "Пропуск $pci_addr."
            continue
        fi

        echo " -> Возврат $pci_addr на драйвер $target_driver"
        python3 "$bind_tool" -b "$target_driver" "$pci_addr"
    done

    echo ""
    echo "Итоговый статус:"
    python3 "$bind_tool" -s || true
    echo "Готово. Если надо, поднимите интерфейсы командой: ip link set <iface> up"
}

list_interfaces() {
    for i in "${!INTERFACES[@]}"; do
        DRIVER=$(ethtool -i "${INTERFACES[$i]}" 2>/dev/null | grep driver | awk '{print $2}')
        DRIVER=${DRIVER:-unknown}
        echo "$((i+1))) ${INTERFACES[$i]} [Driver: $DRIVER]"
    done
}

select_interfaces_and_mode() {
    echo "== Интерфейсы =="
    mapfile -t INTERFACES < <(ls /sys/class/net | grep -v "^lo$")

    if [ "${#INTERFACES[@]}" -eq 0 ]; then
        echo "Сетевые интерфейсы не найдены."
        exit 1
    fi

    echo "-- Port 0 --"
    list_interfaces
    read -r -p "Выбери номер: " IFACE_NUM
    INTERFACE1=${INTERFACES[$((IFACE_NUM-1))]}
    MY_MAC1=$(cat "/sys/class/net/$INTERFACE1/address")
    PCI_ADDR1=$(ethtool -i "$INTERFACE1" | grep bus-info | awk '{print $2}')

    echo "-- Port 1 --"
    list_interfaces
    echo "0) dummy"
    read -r -p "Выбери номер или 0: " IFACE_NUM2

    if [ "$IFACE_NUM2" == "0" ]; then
        INTERFACE2="dummy"
        echo "Режим: Один порт + dummy"
    else
        INTERFACE2=${INTERFACES[$((IFACE_NUM2-1))]}
        MY_MAC2=$(cat "/sys/class/net/$INTERFACE2/address")
        PCI_ADDR2=$(ethtool -i "$INTERFACE2" | grep bus-info | awk '{print $2}')
        echo "Режим: Back-to-back: $INTERFACE1 <-> $INTERFACE2"
    fi

    echo "=== Выбор режима работы ==="
    echo "1) Lab Mode (Software emulation, через ядро Linux)"
    echo "2) Combat Mode (DPDK-oriented, прямой доступ к железу через PCI)"
    read -r -p "Выбери режим (1 или 2): " MODE

    if [ "$MODE" == "1" ]; then
        ip link set "$INTERFACE1" up
        ip link set "$INTERFACE1" promisc on
        if [ "$INTERFACE2" != "dummy" ]; then
            ip link set "$INTERFACE2" up
            ip link set "$INTERFACE2" promisc on
        fi
    fi
}

write_trex_cfg() {
    echo "=== Генерация $TREX_CFG ==="

    if [ "$INTERFACE2" == "dummy" ]; then
        local if_list="[\"$INTERFACE1\", \"dummy\"]"
        [ "$MODE" == "2" ] && if_list="[\"$PCI_ADDR1\", \"dummy\"]"

        cat <<EOF > "$TREX_CFG"
- port_limit: 2
  version: 2
  interfaces: $if_list
  port_info:
    - dest_mac: "ff:ff:ff:ff:ff:ff"
      src_mac:  "$MY_MAC1"
  lat: true
EOF
    else
        local if_list="[\"$INTERFACE1\", \"$INTERFACE2\"]"
        [ "$MODE" == "2" ] && if_list="[\"$PCI_ADDR1\", \"$PCI_ADDR2\"]"

        cat <<EOF > "$TREX_CFG"
- port_limit: 2
  version: 2
  interfaces: $if_list
  port_info:
    - dest_mac: "$MY_MAC2"
      src_mac:  "$MY_MAC1"
    - dest_mac: "$MY_MAC1"
      src_mac:  "$MY_MAC2"
  lat: true
EOF
    fi
}

load_existing_trex_cfg() {
    if [ ! -f "$TREX_CFG" ]; then
        echo "$TREX_CFG не найден."
        echo "Сначала создайте YAML через пункт настройки."
        exit 1
    fi

    echo "=== Используется существующий $TREX_CFG ==="
    echo "YAML не будет изменен."

    MY_MAC1=$(awk -F'"' '/src_mac:/ {print $2; exit}' "$TREX_CFG")
    if [ -z "$MY_MAC1" ]; then
        read -r -p "Не удалось найти src_mac из YAML. Введи MAC для генерации PCAP: " MY_MAC1
    else
        echo "MAC для генерации сценариев: $MY_MAC1"
    fi

    if extract_pci_from_trex_cfg | grep -q .; then
        MODE="2"
        INTERFACE1="existing-yaml-pci"
    else
        MODE="1"
        INTERFACE1="existing-yaml-linux"
    fi
    INTERFACE2="from-existing-yaml"
}

select_and_generate_scenario() {
    cd "$LAUNCH_DIR" || exit 1

    echo "== Выбор сценария =="
    mapfile -t FILES < <(ls "$SCENARIO_DIR"/*.py "$BENCHMARK_DIR"/*.py 2>/dev/null | grep -v "throughput_profile.py")

    if [ "${#FILES[@]}" -eq 0 ]; then
        echo "Сценарии не найдены."
        exit 1
    fi

    echo "Доступные сценарии и тесты:"
    for i in "${!FILES[@]}"; do
        FIRST_LINE=$(head -n 1 "${FILES[$i]}")
        [[ $FIRST_LINE == \#* ]] && DESC=$(echo "$FIRST_LINE" | sed 's/^#//' | xargs) || DESC="нет описания"
        echo "$((i+1))) $(basename "${FILES[$i]}") >> $DESC"
    done

    read -r -p "Выбери номер: " FILE_NUM
    SELECTED_SCRIPT=${FILES[$((FILE_NUM-1))]}
    SCRIPT_NAME=$(basename "$SELECTED_SCRIPT")
    SCRIPT_PATH=$(dirname "$SELECTED_SCRIPT")

    MODE_TYPE="STL"
    local run_owner
    run_owner=$(owner_user)

    if [[ "$SCRIPT_NAME" == *"stateful"* ]]; then
        MODE_TYPE="ASTF"
        echo "Выбран профиль Stateful (ASTF). Генерация PCAP не требуется."
    elif [[ "$SCRIPT_PATH" == *"benchmarks"* ]]; then
        MODE_TYPE="BENCH"
        echo "Выбран тест RFC 2544. Подготовка PCAP..."
        rm -f /tmp/iot_bg_load.pcap /tmp/iot_modbus.pcap /tmp/iot_traffic.pcap 2>/dev/null

        echo " -> Генерация фонового шторма..."
        python3 "$SCENARIO_DIR/iot_load_bidirectional.py" "$MY_MAC1" > /dev/null
        mv -f /tmp/iot_traffic.pcap /tmp/iot_bg_load.pcap

        echo " -> Генерация измерительного потока Modbus..."
        python3 "$SCENARIO_DIR/iot_industrial_modbus.py" "$MY_MAC1" > /dev/null
        mv -f /tmp/iot_traffic.pcap /tmp/iot_modbus.pcap

        chown "$run_owner:$run_owner" /tmp/iot_bg_load.pcap /tmp/iot_modbus.pcap 2>/dev/null || true
    else
        MODE_TYPE="STL"
        echo "Выбран профиль Stateless (STL). Запуск генерации PCAP..."
        rm -f /tmp/iot_traffic.pcap 2>/dev/null
        python3 "$SELECTED_SCRIPT" "$MY_MAC1"
        [ -f /tmp/iot_traffic.pcap ] && chown "$run_owner:$run_owner" /tmp/iot_traffic.pcap 2>/dev/null || true
    fi
}

print_launch_instructions() {
    echo "-------------------------------------------------------"
    echo "НАСТРОЙКА ЗАВЕРШЕНА."
    echo "Режим: $MODE_TYPE | Конфигурация: $INTERFACE1 + $INTERFACE2"
    echo "YAML: $TREX_CFG"
    echo "-------------------------------------------------------"

    echo "ИНСТРУКЦИЯ ПО ЗАПУСКУ:"

    if [ "$MODE_TYPE" == "ASTF" ]; then
        echo "1. Сервер:"
        echo "   cd $TREX_PATH && sudo ./t-rex-64 -i --astf $( [ "$MODE" == "1" ] && echo "--software" )"
        echo ""
        echo "2. Консоль:"
        echo "   cd $TREX_PATH && ./trex-console"
        echo "   # в консоли запуск профиля:"
        echo "   start -f $LAUNCH_DIR/$SELECTED_SCRIPT -m 100"

    elif [ "$MODE_TYPE" == "BENCH" ]; then
        echo "1. Сервер:"
        echo "   cd $TREX_PATH && sudo ./t-rex-64 -i $( [ "$MODE" == "1" ] && echo "--software" )"
        echo ""
        echo "2. Замер:"
        echo "   # после старта сервера:"
        echo "   python3 $SELECTED_SCRIPT"

    else
        echo "1. Сервер:"
        echo "   cd $TREX_PATH && sudo ./t-rex-64 -i $( [ "$MODE" == "1" ] && echo "--software" )"
        echo ""
        echo "2. Консоль:"
        echo "   cd $TREX_PATH && ./trex-console"
        echo "   # одиночная отправка:"
        echo "   push -f /tmp/iot_traffic.pcap -p 0 --force"
        echo ""
        echo "   # постоянная нагрузка:"
        echo "   start -f $LAUNCH_DIR/$SCENARIO_DIR/throughput_profile.py -p 0 -m 10%"
    fi

    if [ "$MODE" == "2" ]; then
        echo ""
        echo "После завершения работы сервера в Combat Mode:"
        echo "   sudo bash $LAUNCH_DIR/setup_generator_trex_IoT.sh"
        echo "   # пункт 4 вернет интерфейсы в Linux"
    fi
    echo "-------------------------------------------------------"
}

echo "=== TRex IoT Generator ==="
echo "1) Генерация сценария по существующему $TREX_CFG (YAML не менять)"
echo "2) Настройка YAML + генерация (если TRex уже стоит)"
echo "3) Полная установка TRex + настройка YAML + генерация"
echo "4) Вернуть DPDK-интерфейсы в Linux"
read -r -p "Твой выбор: " START_MODE

case "$START_MODE" in
    1)
        require_trex_path
        load_existing_trex_cfg
        select_and_generate_scenario
        print_launch_instructions
        ;;
    2)
        require_trex_path
        select_interfaces_and_mode
        write_trex_cfg
        select_and_generate_scenario
        print_launch_instructions
        ;;
    3)
        install_trex
        require_trex_path
        select_interfaces_and_mode
        write_trex_cfg
        select_and_generate_scenario
        print_launch_instructions
        ;;
    4)
        release_dpdk_interfaces
        ;;
    *)
        echo "Нет такого пункта: $START_MODE"
        exit 1
        ;;
esac
