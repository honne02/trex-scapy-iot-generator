#!/bin/bash

# Настройки (изменяемые под твой конфиг)
INTERFACE="ens37"
TREX_DIR="/opt/trex"
TREX_VER="v3.08"
MY_MAC=$(cat /sys/class/net/$INTERFACE/address)

echo "=== [1/5] Установка системных зависимостей ==="
apt update
apt install -y ca-certificates python3-pip python3-scapy tcpdump wget tar

echo "=== [2/5] Подготовка сетевого интерфейса $INTERFACE ==="
ip link set $INTERFACE up
ip link set $INTERFACE promisc on

echo "=== [3/5] Загрузка и установка Cisco TRex ($TREX_VER) ==="
mkdir -p $TREX_DIR
cd $TREX_DIR

# Удаляем старые архивы если есть
rm -f latest latest.tar.gz

wget --no-check-certificate https://trex-tgn.cisco.com/trex/release/latest -O latest.tar.gz
tar -xzvf latest.tar.gz
chmod -R 755 $TREX_DIR

echo "=== [4/5] Создание конфигурации /etc/trex_cfg.yaml ==="
cat <<EOF > /etc/trex_cfg.yaml
- port_limit: 2
  version: 2
  interfaces: ["$INTERFACE", "dummy"]
  port_info:
    - dest_mac: "ff:ff:ff:ff:ff:ff"
      src_mac:  "$MY_MAC"
    - dest_mac: "00:00:00:00:00:00"
      src_mac:  "00:00:00:00:00:00"
EOF

echo "=== [5/5] Создание Python-генератора IoT трафика ==="
cat <<EOF > ~/gen_iot_v2.py
from scapy.all import *
from scapy.layers.inet import IP, UDP, Ether

pkts = []
print("Генерация 100 пакетов CoAP для 100 датчиков...")

for i in range(1, 101):
    p = (Ether(src="$MY_MAC", dst="ff:ff:ff:ff:ff:ff") / 
         IP(src=f"10.0.0.{i}", dst="192.168.1.100") / 
         UDP(sport=5683, dport=5683) / 
         Raw(load=b"\x40\x01\x12\x34\xbb\x74\x65\x6d\x70\x3d\x32\x32"))
    pkts.append(p)

wrpcap('/tmp/iot_traffic_v2.pcap', pkts)
print("Файл сохранен: /tmp/iot_traffic_v2.pcap")
EOF

echo "======================================================="
echo "УСТАНОВКА ЗАВЕРШЕНА!"
echo "MAC-адрес интерфейса $INTERFACE: $MY_MAC"
echo "======================================================="