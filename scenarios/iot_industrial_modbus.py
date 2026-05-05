# Сценарий: Имитация промышленного трафика (Modbus/TCP) для замера Latency
from scapy.all import *
from scapy.layers.inet import IP, TCP, Ether
import sys

def run(mac):
    pkts = []
    # Имитируем запрос Modbus Read Holding Registers
    # MBAP Header (7 байт) + PDU (5 байт) = 12 байт. 
    # Этого мало для TRex Latency, добавляем Padding.
    
    for i in range(1, 31):
        payload = (
            b"\x00\x01" # Transaction ID
            b"\x00\x00" # Protocol ID
            b"\x00\x06" # Length
            b"\x01"     # Unit ID
            b"\x03"     # Function Code: Read Holding Registers
            b"\x00\x00" # Starting Address
            b"\x00\x0a" # Quantity of Registers
            b"\x00" * 10 # ПАДДИНГ: Добавляем пустые байты, чтобы payload стал > 16 байт
        )
        
        p = (Ether(src=mac, dst="ff:ff:ff:ff:ff:ff") / 
             IP(src=f"10.0.2.{i}", dst="192.168.1.100") / 
             TCP(sport=502, dport=502, flags="PA") / 
             Raw(load=payload))
        pkts.append(p)

    wrpcap('/tmp/iot_traffic.pcap', pkts)
    print("Modbus/TCP трафик (с паддингом для Latency) создан в /tmp/iot_traffic.pcap")

if __name__ == "__main__":
    if len(sys.argv) > 1:
        run(sys.argv[1])
    else:
        run("00:00:00:00:00:00")