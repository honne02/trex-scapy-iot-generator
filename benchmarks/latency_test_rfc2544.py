# Автоматизированный замер Latency/Jitter по методике RFC 2544 (120/60 сек)

import sys
import os
import time

# --- БЛОК ПОДКЛЮЧЕНИЯ БИБЛИОТЕК TREX ---
def add_trex_paths():
    base_dir = '/opt/trex'
    if not os.path.exists(base_dir):
        print(f"[!] Ошибка: Директория {base_dir} не найдена.")
        sys.exit(1)
    
    # Находим последнюю версию TRex (папки v3.xx)
    versions = [d for d in os.listdir(base_dir) if d.startswith('v') and os.path.isdir(os.path.join(base_dir, d))]
    if not versions:
        print("[!] Ошибка: Версии TRex не найдены в /opt/trex.")
        sys.exit(1)
        
    latest_ver = sorted(versions)[-1]
    trex_path = os.path.join(base_dir, latest_ver, 'automation/trex_control_plane/interactive')
    
    if trex_path not in sys.path:
        sys.path.insert(0, trex_path)
        print(f"[*] Используются библиотеки TRex из: {trex_path}")

add_trex_paths()

# Теперь импортируем API TRex
from trex_stl_lib.api import *

LATENCY_PG_ID = 12

def get_pg_stats(stats_section, pg_id):
    return stats_section.get(pg_id) or stats_section.get(str(pg_id))

def get_latency_stats(stats, flow_data, pg_id):
    if 'latency' in flow_data:
        return flow_data['latency']

    pg_latency = get_pg_stats(stats.get('latency', {}), pg_id)
    if isinstance(pg_latency, dict):
        return pg_latency.get('latency', pg_latency)

    return None

def run_rfc2544_test(server_ip="127.0.0.1", duration=120, warm_up=60):
    # Пути к заранее сгенерированным PCAP файлам
    bg_pcap = "/tmp/iot_bg_load.pcap"
    modbus_pcap = "/tmp/iot_modbus.pcap"

    # Проверка наличия файлов
    if not os.path.exists(bg_pcap) or not os.path.exists(modbus_pcap):
        print("[!] Ошибка: Не найдены PCAP файлы в /tmp/. Сначала запусти генерацию в меню Bash.")
        return

    c = STLClient(server = server_ip)
    
    try:
        print(f"[*] Подключение к серверу {server_ip}...")
        c.connect()
        c.reset(ports = [0])

        # 1. Определение потоков
        # Фоновая нагрузка (CoAP шторм + OTA обновления) - 50% канала
        bg_stream = STLStream(
            packet = STLPktBuilder(pkt = bg_pcap),
            mode = STLTXCont(percentage = 50)
        )

        # Контрольный поток (Modbus/TCP) для замера задержки
        # Используем flow_stats для аппаратного измерения Latency
        modbus_stream = STLStream(
            packet = STLPktBuilder(pkt = modbus_pcap),
            mode = STLTXCont(pps = 100), 
            flow_stats = STLFlowLatencyStats(pg_id = LATENCY_PG_ID) # Уникальный ID для статистики
        )

        c.add_streams([bg_stream, modbus_stream], ports = [0])

        print(f"[*] Старт теста. Общая длительность: {duration} сек.")
        c.start(ports = [0], duration = duration)

        # ЭТАП 1: Прогрев (Стабилизация очередей и ARP)
        print(f"[*] Фаза 1: Стабилизация нагрузки ({warm_up} сек)...")
        time.sleep(warm_up)

        # ЭТАП 2: Сброс и чистый замер
        # Ключевое действие по RFC 2544: обнуляем счетчики прямо во время генерации
        print(f"[*] Фаза 2: Сброс статистики и начало замера (осталось {duration - warm_up} сек)...")
        c.clear_stats() 
        
        time.sleep(duration - warm_up)

        # Сбор финальных данных
        stats = c.get_stats()
        
        # Проверяем, есть ли данные по нашему pg_id
        flow_data = get_pg_stats(stats.get('flow_stats', {}), LATENCY_PG_ID)
        if flow_data:
            rx_pkts = flow_data['rx_pkts']['total']
            lat_stats = get_latency_stats(stats, flow_data, LATENCY_PG_ID)
            
            print("\n" + "="*40)
            print("   РЕЗУЛЬТАТЫ QoS (МЕТОДИКА RFC 2544)   ")
            print("="*40)
            print(f"Пакет на приеме (Rx): {rx_pkts}")

            if lat_stats and rx_pkts > 0:
                print(f"Средняя задержка (RTT):  {lat_stats['average']} мкс")
                print(f"Джиттер (Jitter):       {lat_stats['jitter']} мкс")
                print(f"Макс. задержка (Max):   {lat_stats['total_max']} мкс")
                print(f"Мин. задержка (Min):    {lat_stats['total_min']} мкс")
            elif rx_pkts > 0:
                print("[!] Пакеты вернулись, но TRex не отдал latency-метрики.")
                print(f"[i] Проверь секцию stats['latency'] для pg_id={LATENCY_PG_ID}.")
            else:
                print("[!] Данные о задержке отсутствуют: пакеты не вернулись на порт Rx.")
            print("="*40)
        else:
            print(f"[!] Ошибка: Статистика по pg_id={LATENCY_PG_ID} не найдена.")

    except STLError as e:
        print(f"[!] Ошибка TRex: {e}")
    finally:
        c.disconnect()
        print("[*] Сессия завершена.")

if __name__ == "__main__":
    run_rfc2544_test()
