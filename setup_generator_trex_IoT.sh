#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "Запусти через sudo!"
   exit 1
fi

# Сохраняем путь, откуда запущен скрипт
LAUNCH_DIR=$(pwd)
TREX_DIR="/opt/trex"
SCENARIO_DIR="./scenarios"
BENCHMARK_DIR="./benchmarks"

echo "=== [1/6] Быстрый запуск или Полная установка? ==="
echo "1) Только генерация (если TRex уже стоит)"
echo "2) Полная установка (с нуля)"
read -p "Твой выбор: " START_MODE

echo "=== [2/6] Сканирование интерфейсов ==="
INTERFACES=($(ls /sys/class/net | grep -v "lo"))

echo "Доступные интерфейсы:"
for i in "${!INTERFACES[@]}"; do
    DRIVER=$(ethtool -i ${INTERFACES[$i]} | grep driver | awk '{print $2}')
    echo "$((i+1))) ${INTERFACES[$i]} [Driver: $DRIVER]"
done

read -p "Выбери номер интерфейса: " IFACE_NUM
INTERFACE=${INTERFACES[$((IFACE_NUM-1))]}
MY_MAC=$(cat /sys/class/net/$INTERFACE/address)
PCI_ADDR=$(ethtool -i $INTERFACE | grep bus-info | awk '{print $2}')

if [ "$START_MODE" == "2" ]; then
    echo "=== [3/6] Установка зависимостей и TRex ==="
    apt update && apt install -y python3-scapy tcpdump wget tar ethtool unzip
    mkdir -p $TREX_DIR && cd $TREX_DIR
    
    if [ -f "/tmp/latest.tar.gz" ]; then
        cp /tmp/latest.tar.gz .
    else
        wget --no-check-certificate https://trex-tgn.cisco.com/trex/release/latest -O latest.tar.gz
    fi
    tar -xzvf latest.tar.gz
fi

# Находим путь к TRex
TREX_VER_DIR=$(find $TREX_DIR -maxdepth 1 -type d -name "v*" | head -n 1 | sed 's|.*/||')
TREX_PATH="$TREX_DIR/$TREX_VER_DIR"

if [ -z "$TREX_VER_DIR" ]; then
    echo "Ошибка: TRex не найден в $TREX_DIR. Запусти полную установку."
    exit 1
fi

echo "=== [4/6] Выбор режима работы ==="
echo "1) Lab Mode (Software emulation, через ядро Linux)"
echo "2) Combat Mode (DPDK-oriented, прямой доступ к железу через PCI)"
read -p "Выбери режим (1 или 2): " MODE

if [ "$MODE" == "1" ]; then
    ip link set $INTERFACE up
    ip link set $INTERFACE promisc on
fi

# Обновляем конфиг /etc/trex_cfg.yaml
if [ "$MODE" == "2" ]; then
    cat <<EOF > /etc/trex_cfg.yaml
- port_limit: 2
  version: 2
  interfaces: ["$PCI_ADDR", "dummy"]
  port_info:
    - dest_mac: "ff:ff:ff:ff:ff:ff"
      src_mac:  "$MY_MAC"
EOF
else
    cat <<EOF > /etc/trex_cfg.yaml
- port_limit: 2
  version: 2
  interfaces: ["$INTERFACE", "dummy"]
  port_info:
    - dest_mac: "ff:ff:ff:ff:ff:ff"
      src_mac:  "$MY_MAC"
EOF
fi

cd $LAUNCH_DIR

echo "=== [5/6] ДИНАМИЧЕСКИЙ ВЫБОР СЦЕНАРИЯ ==="
# Собираем список из обеих папок
FILES=($(ls $SCENARIO_DIR/*.py $BENCHMARK_DIR/*.py 2>/dev/null))

echo "Доступные сценарии и тесты:"
for i in "${!FILES[@]}"; do
    FIRST_LINE=$(head -n 1 "${FILES[$i]}")
    [[ $FIRST_LINE == \#* ]] && DESC=$(echo "$FIRST_LINE" | sed 's/^#//' | xargs) || DESC="нет описания"
    echo "$((i+1))) $(basename ${FILES[$i]}) >> $DESC"
done

read -p "Выбери номер: " FILE_NUM
SELECTED_SCRIPT=${FILES[$((FILE_NUM-1))]}
SCRIPT_NAME=$(basename "$SELECTED_SCRIPT")
SCRIPT_PATH=$(dirname "$SELECTED_SCRIPT")

# ЛОГИКА РАЗДЕЛЕНИЯ РЕЖИМОВ
MODE_TYPE="STL"
if [[ "$SCRIPT_NAME" == *"stateful"* ]]; then
    MODE_TYPE="ASTF"
    echo "Выбран профиль Stateful (ASTF). Генерация PCAP не требуется."
elif [[ "$SCRIPT_PATH" == *"benchmarks"* ]]; then
    MODE_TYPE="BENCH"
    echo "Выбран автоматизированный тест RFC 2544. Подготовка окружения..."
    # Для теста задержки нужны два файла, генерируем их
    python3 "$SCENARIO_DIR/iot_load_bidirectional.py" "$MY_MAC"
    python3 "$SCENARIO_DIR/iot_industrial_modbus.py" "$MY_MAC"
    mv /tmp/iot_traffic.pcap /tmp/iot_modbus.pcap
else
    MODE_TYPE="STL"
    echo "Выбран профиль Stateless (STL). Запуск генерации PCAP..."
    python3 "$SELECTED_SCRIPT" "$MY_MAC"
    [ -f /tmp/iot_traffic.pcap ] && chown $SUDO_USER:$SUDO_USER /tmp/iot_traffic.pcap
fi

echo "======================================================="
echo "УСТАНОВКА ЗАВЕРШЕНА!"
echo "Режим стенда: $MODE_TYPE"
echo "======================================================="

echo "ИНСТРУКЦИЯ ПО ЗАПУСКУ:"

if [ "$MODE_TYPE" == "ASTF" ]; then
    echo "1. Сервер (Окно 1):"
    echo "   cd $TREX_PATH && sudo ./t-rex-64 -i --astf $( [ "$MODE" == "1" ] && echo "--software" )"
    echo ""
    echo "2. Управление (Окно 2):"
    echo "   cd $TREX_PATH && ./trex-console"
    echo "   # В консоли запусти профиль:"
    echo "   start -f $LAUNCH_DIR/$SELECTED_SCRIPT -m 100"

elif [ "$MODE_TYPE" == "BENCH" ]; then
    echo "1. Сервер (Окно 1):"
    echo "   cd $TREX_PATH && sudo ./t-rex-64 -i $( [ "$MODE" == "1" ] && echo "--software" )"
    echo ""
    echo "2. Запуск автоматизированного замера (Окно 2):"
    echo "   # Убедись, что сервер запущен, затем выполни:"
    echo "   python3 $SELECTED_SCRIPT"

else
    echo "1. Сервер (Окно 1):"
    echo "   cd $TREX_PATH && sudo ./t-rex-64 -i $( [ "$MODE" == "1" ] && echo "--software" )"
    echo ""
    echo "2. Управление (Окно 2):"
    echo "   cd $TREX_PATH && ./trex-console"
    echo "   # В консоли отправь трафик:"
    echo "   push -f /tmp/iot_traffic.pcap -p 0 --force"
fi
echo "======================================================="