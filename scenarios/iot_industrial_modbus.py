# Сценарий 3: Имитация промышленного трафика (Modbus/TCP) для мониторинга состояния контроллеров (ПЛК) в индустриальных сетях (IIoT).
from scapy.all import *
from scapy.layers.inet import IP, TCP, Ether
import sys

def run(mac):
    pkts = []
    # Имитируем опрос 30 промышленных контроллеров
    gateway_ip = "192.168.1.100"
    
    for i in range(1, 31):
        # Modbus/TCP использует порт 502
        # Создаем запрос Read Holding Registers (Function Code 3)
        modbus_payload = b"\x00\x01" # Transaction ID
        modbus_payload += b"\x00\x00" # Protocol ID (0 = Modbus)
        modbus_payload += b"\x00\x06" # Length
        modbus_payload += b"\x01"     # Unit ID
        modbus_payload += b"\x03"     # Function Code (Read)
        modbus_payload += b"\x00\x6B\x00\x01" # Start Address and Quantity
        
        p = (Ether(src=mac, dst="ff:ff:ff:ff:ff:ff") / 
             IP(src=f"10.0.5.{i}", dst=gateway_ip) / 
             TCP(sport=1024 + i, dport=502, flags="PA") / 
             Raw(load=modbus_payload))
        pkts.append(p)
        
    wrpcap('/tmp/iot_traffic.pcap', pkts)
    print("Modbus/TCP трафик сгенерирован в /tmp/iot_traffic.pcap")

if __name__ == "__main__":
    if len(sys.argv) > 1:
        run(sys.argv[1])
    else:
        print("Ошибка: не передан MAC-адрес")