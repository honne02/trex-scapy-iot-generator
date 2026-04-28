# Сценарий 1: Имитация сбора данных с сенсорного поля (100 датчиков) по протоколу CoAP для тестирования нагрузки на шлюз.
from scapy.all import *
from scapy.layers.inet import IP, UDP, Ether
import sys

def run(mac):
    pkts = []
    for i in range(1, 101):
        p = (Ether(src=mac, dst="ff:ff:ff:ff:ff:ff") / 
             IP(src=f"10.0.0.{i}", dst="192.168.1.100") / 
             UDP(sport=5683, dport=5683) / 
             Raw(load=b"\x40\x01\x12\x34\xbb\x74\x65\x6d\x70\x3d\x32\x32"))
        pkts.append(p)
    wrpcap('/tmp/iot_traffic.pcap', pkts)

if __name__ == "__main__":
    run(sys.argv[1])