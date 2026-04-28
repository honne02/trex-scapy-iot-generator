# Сценарий 5: Комбинированный стресс-тест (Q.3900 Уровень 2.2) — одновременная эмуляция 150 устройств CoAP и MQTT для проверки NAT/ARP шлюза.
from scapy.all import *
from scapy.layers.inet import IP, UDP, TCP, Ether
import sys

def run(mac):
    pkts = []
    gateway_ip = "192.168.1.100"
    
    print("Генерация комбинированного трафика (150 агентов)...")
    
    # 1. Генерируем 100 CoAP сенсоров (Подсеть 10.0.0.0/24)
    for i in range(1, 101):
        p = (Ether(src=RandMAC(), dst="ff:ff:ff:ff:ff:ff") / 
             IP(src=f"10.0.0.{i}", dst=gateway_ip) / 
             UDP(sport=5683, dport=5683) / 
             Raw(load=b"\x40\x01\x12\x34\xbb\x74\x65\x6d\x70\x3d\x22"))
        pkts.append(p)

    # 2. Генерируем 50 MQTT устройств (Подсеть 10.0.1.0/24)
    for i in range(1, 51):
        p = (Ether(src=RandMAC(), dst="ff:ff:ff:ff:ff:ff") / 
             IP(src=f"10.0.1.{i}", dst=gateway_ip) / 
             TCP(sport=1883, dport=1883, flags="PA") / 
             Raw(load=b"\x30\x12\x00\x04MQTT\x04\x02\x00\x3c\x00\x06device"))
        pkts.append(p)

    wrpcap('/tmp/iot_traffic.pcap', pkts)
    print(f"Стресс-тест подготовлен: 150 уникальных L2/L3 пар в /tmp/iot_traffic.pcap")

if __name__ == "__main__":
    run(sys.argv[1])