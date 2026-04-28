# Сценарий 4: Моделирование процесса обновления ПО (OTA Update) с передачей крупных блоков данных от сервера к устройствам.
from scapy.all import *
from scapy.layers.inet import IP, TCP, Ether
import sys

def run(mac):
    pkts = []
    # Имитируем передачу прошивки блоками
    for i in range(1, 51):
        p = (Ether(src=mac, dst="ff:ff:ff:ff:ff:ff") / 
             IP(src="192.168.1.100", dst=f"10.0.0.{i}") / 
             TCP(sport=8080, dport=80, flags="PA") / 
             Raw(load=b"FIRMWARE_DATA_BLOCK_" + b"X"*100))
        pkts.append(p)
    wrpcap('/tmp/iot_traffic.pcap', pkts)

if __name__ == "__main__":
    run(sys.argv[1])