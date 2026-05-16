from scapy.all import *
from scapy.layers.inet import IP, UDP, TCP, Ether
import sys

def run(mac_from_arg):
    pkts = []
    server_ip = "192.168.1.100"
    
    # MAC сервера (берем из аргумента или ставим фиксированный)
    server_side_mac = mac_from_arg if mac_from_arg != "dummy" else "00:00:00:00:00:02"

    print(f"--- Генерация: Датчики (Random MAC) <-> Сервер ({server_side_mac}) ---")

    # Цикл имитации 100 устройств
    for i in range(1, 101):
        # Генерируем уникальный случайный MAC для каждого датчика
        sensor_mac = RandMAC()
        client_ip = f"10.0.0.{i}"
        
        # 1. UPLINK: Датчик -> Сервер (UDP 5683)
        # Используем sensor_mac как отправителя
        uplink_pkt = (Ether(src=sensor_mac, dst=server_side_mac) / 
                      IP(src=client_ip, dst=server_ip) / 
                      UDP(sport=5683, dport=5683) / 
                      Raw(load=b"a"*22)) 
        pkts.append(uplink_pkt)

        # 2. DOWNLINK: Сервер -> Датчик (TCP 8080 -> 80)
        # Ответы шлем первым 50 датчикам для асимметрии
        if i <= 50:
            downlink_pkt = (Ether(src=server_side_mac, dst=sensor_mac) / 
                            IP(src=server_ip, dst=client_ip) / 
                            TCP(sport=8080, dport=80, flags="PA") / 
                            Raw(load=b"F"*1000))
            pkts.append(downlink_pkt)

    output_path = '/tmp/iot_traffic.pcap'
    wrpcap(output_path, pkts)
    print(f"Успешно создано {len(pkts)} пакетов.")
    print(f"Uplink: 100 пакетов с уникальными MAC.")
    print(f"Downlink: 50 тяжелых TCP ответов.")
    print(f"Можно запустить в --dual режиме, если два порта.")
    print(f"PCAP сохранен в: {output_path}")

if __name__ == "__main__":
    if len(sys.argv) > 1:
        run(sys.argv[1])
    else:
        run("dummy")