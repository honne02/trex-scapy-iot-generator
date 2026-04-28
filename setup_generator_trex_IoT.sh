#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "Запусти через sudo!"
   exit 1
fi

# Сохраняем путь, откуда запущен скрипт
LAUNCH_DIR=$(pwd)
TREX_DIR="/opt/trex"

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

# Пропускаем установку, если выбран пункт 1
if [ "$START_MODE" == "2" ]; then
    echo "=== [3/6] Установка зависимостей и TRex ==="
    apt update && apt install -y python3-scapy tcpdump wget tar ethtool unzip
    mkdir -p $TREX_DIR && cd $TREX_DIR
    
    # Пытаемся найти локальный ZIP/TAR или качаем
    if [ -f "/tmp/latest.tar.gz" ]; then
        cp /tmp/latest.tar.gz .
    else
        wget --no-check-certificate https://trex-tgn.cisco.com/trex/release/latest -O latest.tar.gz
    fi
    tar -xzvf latest.tar.gz
fi

# Находим путь к TRex в любом случае
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

# Переходим к сценариям
cd $LAUNCH_DIR
echo "=== [5/6] ВЫБОР СЦЕНАРИЯ ==="
SCENARIO_DIR="./scenarios"
FILES=($(ls $SCENARIO_DIR/*.py 2>/dev/null))

for i in "${!FILES[@]}"; do
    DESC=$(head -n 1 "${FILES[$i]}" | sed 's/^#//' | xargs)
    echo "$((i+1))) $(basename ${FILES[$i]}) >> ${DESC:-нет описания}"
done

read -p "Номер сценария: " FILE_NUM
SELECTED_SCRIPT=${FILES[$((FILE_NUM-1))]}
python3 "$SELECTED_SCRIPT" "$MY_MAC"

echo "======================================================="
echo "ГОТОВО! TRex настроен под сценарий: $(basename $SELECTED_SCRIPT)"
echo "Запуск сервера: cd $TREX_PATH && sudo ./t-rex-64 -i $( [ "$MODE" == "1" ] && echo "--software" )"
echo "Запуск консоли: cd $TREX_PATH && ./trex-console"
echo "В консоли: push -f /tmp/iot_traffic.pcap -p 0 --force"
echo "======================================================="