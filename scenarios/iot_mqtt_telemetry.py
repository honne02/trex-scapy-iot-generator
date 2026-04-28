# Сценарий 2: Имитация MQTT-телеметрии от распределенных умных устройств к центральному брокеру для анализа стабильности сессий.
from scapy.all import *
from scapy.layers.inet import IP, TCP, Ether
import sys

def run(mac):
    pkts = []
    for i in range(1, 51):
        p = (Ether(src=mac, dst="ff:ff:ff:ff:ff:ff") / 
             IP(src=f"10.0.1.{i}", dst="192.168.1.100") / 
             TCP(sport=1883, dport=1883, flags="PA") / 
             Raw(load=b"\x30\x12\x00\x04MQTT\x04\x02\x00\x3c\x00\x06device"))
        pkts.append(p)
    wrpcap('/tmp/iot_traffic.pcap', pkts)

if __name__ == "__main__":
    run(sys.argv[1])