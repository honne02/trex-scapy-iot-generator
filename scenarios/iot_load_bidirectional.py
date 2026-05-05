from scapy.all import *
from scapy.layers.inet import IP, UDP, TCP, Ether
import sys

def run(mac):
    pkts = []
    server_ip = "192.168.1.100"
    
    # Uplink: 100 датчиков (64 байта)
    for i in range(1, 101):
        p = (Ether(src=RandMAC(), dst="ff:ff:ff:ff:ff:ff") / 
             IP(src=f"10.0.0.{i}", dst=server_ip) / 
             UDP(sport=5683, dport=5683) / 
             Raw(load=b"a"*22)) 
        pkts.append(p)

    # Downlink: Ответы сервера (TCP нагрузка)
    for i in range(1, 51):
        p = (Ether(src=mac, dst="ff:ff:ff:ff:ff:ff") / 
             IP(src=server_ip, dst=f"10.0.0.{i}") / 
             TCP(sport=8080, dport=80, flags="PA") / 
             Raw(load=b"F"*1000))
        pkts.append(p)

    wrpcap('/tmp/iot_load_bidirectional.pcap', pkts)
    print("Файл /tmp/iot_load_bidirectional.pcap успешно создан")

if __name__ == "__main__":
    if len(sys.argv) > 1:
        run(sys.argv[1])
    else:
        print("Ошибка: не передан MAC")