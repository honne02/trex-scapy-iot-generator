# Профиль-обертка для цикличной генерации PCAP-файлов (режим STLTXCont).
# Используется для поиска пропускной способности (Throughput) по RFC 2544.

from trex_stl_lib.api import *

class ThroughputProfile:
    # Обязательный метод для STL-профилей
    def get_streams(self, direction=0, **kwargs):
        pcap_file = "/tmp/iot_traffic.pcap"
        
        stream = STLStream(
            packet = STLPktBuilder(pkt = pcap_file),
            mode = STLTXCont() # Непрерывный (зацикленный) режим
        )
        # Обязательно возвращаем список (массив) потоков!
        return [stream]

def register():
    return ThroughputProfile()