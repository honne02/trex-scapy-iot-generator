#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "Запусти через sudo!"
   exit 1
fi

echo "=== [1/6] Сканирование и проверка совместимости NIC ==="
INTERFACES=($(ls /sys/class/net | grep -v "lo"))
TREX_DIR="/opt/trex"
CURRENT_DIR=$(pwd)

echo "Доступные интерфейсы и их драйверы:"
for i in "${!INTERFACES[@]}"; do
    DRIVER=$(ethtool -i ${INTERFACES[$i]} | grep driver | awk '{print $2}')
    PCI=$(ethtool -i ${INTERFACES[$i]} | grep bus-info | awk '{print $2}')
    echo "$((i+1))) ${INTERFACES[$i]} [Driver: $DRIVER] [PCI: $PCI]"
done

read -p "Выбери номер интерфейса для генерации: " IFACE_NUM
INTERFACE=${INTERFACES[$((IFACE_NUM-1))]}

if [ -z "$INTERFACE" ]; then echo "Ошибка выбора!"; exit 1; fi

# Получаем данные выбранной карты
MY_MAC=$(cat /sys/class/net/$INTERFACE/address)
PCI_ADDR=$(ethtool -i $INTERFACE | grep bus-info | awk '{print $2}')
DRIVER=$(ethtool -i $INTERFACE | grep driver | awk '{print $2}')

echo "ФОРСИРОВАННЫЙ ПОДЪЕМ ЛИНКА"
if [ "$MODE" == "1" ]; then
    echo "Настройка интерфейса $INTERFACE для Lab Mode..."
    ip link set $INTERFACE up
    ip link set $INTERFACE promisc on
    
    # Ждем, пока драйвер осознает реальность (актуально для VMware)
    echo "Ожидание активации линка (Carrier)..."
    for i in {1..5}; do
        STATE=$(cat /sys/class/net/$INTERFACE/operstate)
        if [ "$STATE" == "up" ] || [ "$STATE" == "unknown" ]; then
            echo "Линк поднят! Текущее состояние: $STATE"
            break
        fi
        echo "Попытка $i: линк всё еще $STATE, жду..."
        ip link set $INTERFACE up
        sleep 2
    done
fi


echo "=== [2/6] Выбор режима работы ==="
echo "1) Lab Mode (Software emulation, через ядро Linux)"
echo "2) Combat Mode (DPDK-oriented, прямой доступ к железу через PCI)"
read -p "Выбери режим (1 или 2): " MODE

echo "=== [3/6] Установка зависимостей и TRex ==="
apt update && apt install -y python3-scapy tcpdump wget tar ethtool
mkdir -p $TREX_DIR && cd $TREX_DIR
wget --no-check-certificate https://trex-tgn.cisco.com/trex/release/latest -O latest.tar.gz
tar -xzvf latest.tar.gz
TREX_VER_DIR=$(find . -maxdepth 1 -type d -name "v*" | head -n 1 | sed 's|./||')

echo "=== [4/6] Генерация конфигурации /etc/trex_cfg.yaml ==="
if [ "$MODE" == "2" ]; then
    # Боевой конфиг на PCI адресах
    cat <<EOF > /etc/trex_cfg.yaml
- port_limit: 2
  version: 2
  interfaces: ["$PCI_ADDR", "dummy"]
  port_info:
    - dest_mac: "ff:ff:ff:ff:ff:ff"
      src_mac:  "$MY_MAC"
EOF
    echo "ВНИМАНИЕ: В Combat Mode интерфейс будет 'украден' у Linux и передан DPDK."
else
    # Лабораторный конфиг на именах
    cat <<EOF > /etc/trex_cfg.yaml
- port_limit: 2
  version: 2
  interfaces: ["$INTERFACE", "dummy"]
  port_info:
    - dest_mac: "ff:ff:ff:ff:ff:ff"
      src_mac:  "$MY_MAC"
EOF
fi

echo "=== [5/6] Создание генератора в папке проекта ==="
cat <<EOF > "$CURRENT_DIR/gen_iot_v2.py"
from scapy.all import *
from scapy.layers.inet import IP, UDP, Ether
pkts = []
for i in range(1, 101):
    p = (Ether(src="$MY_MAC", dst="ff:ff:ff:ff:ff:ff") / 
         IP(src=f"10.0.0.{i}", dst="192.168.1.100") / 
         UDP(sport=5683, dport=5683) / 
         Raw(load=b"\x40\x01\x12\x34\xbb\x74\x65\x6d\x70\x3d\x32\x32"))
    pkts.append(p)
wrpcap('/tmp/iot_traffic_v2.pcap', pkts)
print("PCAP готов в /tmp/iot_traffic_v2.pcap")
EOF

[ "$SUDO_USER" ] && chown $SUDO_USER:$SUDO_USER "$CURRENT_DIR/gen_iot_v2.py"
TREX_PATH="/opt/trex/$TREX_VER_DIR"
GEN_SCRIPT="$CURRENT_DIR/gen_iot_v2.py"

echo "======================================================="
echo "УСТАНОВКА ЗАВЕРШЕНА!"
echo "Режим: $( [ "$MODE" == "2" ] && echo "COMBAT (DPDK)" || echo "LAB (Software)" )"
echo "======================================================="
echo "ИНСТРУКЦИЯ ПО ЗАПУСКУ СТЕНДА"
echo "1. Сгенерируй трафик:"
echo "   python3 $GEN_SCRIPT"
echo ""
echo "2. В ПЕРВОМ ОКНЕ запусти сервер:"
echo "   cd $TREX_PATH && sudo ./t-rex-64 -i --software"
echo ""
echo "3. ВО ВТОРОМ ОКНЕ запусти управление:"
echo "   cd $TREX_PATH && ./trex-console"
echo "   # В консоли введи:"
echo "   push -f /tmp/iot_traffic_v2.pcap -p 0 --force"
echo "======================================================="