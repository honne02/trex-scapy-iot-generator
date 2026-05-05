# benchmarks/rfc2544_latency_manager.py
from trex_stl_lib.api import *
import time
import sys

def run_benchmark(percentage=50):
    c = STLClient()
    try:
        c.connect()
        c.reset(ports = [0])
        
        # Поток 1: Фон (Uplink/Downlink шторм)
        s1 = STLStream(packet = STLPktBuilder(pkt="/tmp/iot_load_bidirectional.pcap"),
                       mode = STLTXCont(percentage = percentage))
        
        # Поток 2: Контрольный (Modbus RTT)
        s2 = STLStream(packet = STLPktBuilder(pkt="/tmp/iot_modbus.pcap"),
                       mode = STLTXCont(pps = 100),
                       flow_stats = STLFlowLatencyStats(pg_id = 5))
        
        c.add_streams([s1, s2], ports = [0])
        
        print(f"--- Старт RFC 2544 (Нагрузка {percentage}%). Фаза 1: Прогрев (60с) ---")
        c.start(ports = [0], duration = 120)
        time.sleep(60)
        
        print("--- Фаза 2: Сброс статистики и чистый замер (60с) ---")
        c.clear_stats()
        time.sleep(60)
        
        stats = c.get_stats()
        lat = stats['flow_stats'][5]['latency']
        
        print("\n[РЕЗУЛЬТАТЫ]")
        print(f"AVG_RTT: {lat['average']} us | JITTER: {lat['jitter']} us | MAX: {lat['total_max']} us")
        
    finally:
        c.disconnect()

if __name__ == "__main__":
    perc = int(sys.argv[1]) if len(sys.argv) > 1 else 50
    run_benchmark(perc)