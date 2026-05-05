# Сценарий Stateful: Эмуляция HTTP-трафика IoT-устройств (Handshake + L7 Data Exchange) для верификации DPI.
from trex.astf.api import *

class Prof1:
    def __init__(self):
        pass

    def get_profile(self, **kwargs):
        # 1. Описываем L7-поведение клиента
        prog_c = ASTFProgram()
        prog_c.send(b"GET /config.json HTTP/1.1\r\nHost: iot-server.local\r\n\r\n")
        prog_c.recv(50) 

        # 2. Описываем L7-поведение сервера
        prog_s = ASTFProgram()
        prog_s.recv(len(b"GET /config.json HTTP/1.1\r\nHost: iot-server.local\r\n\r\n"))
        prog_s.send(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"status\":\"ok\"}")

        # 3. Шаблоны TCP сессии
        temp_c = ASTFTCPClientTemplate(program=prog_c, port=80)
        temp_s = ASTFTCPServerTemplate(program=prog_s)
        template = ASTFTemplate(client_template=temp_c, server_template=temp_s)

        # 4. Генератор IP-адресов
        ip_gen_c = ASTFIPGenDist(ip_range=["16.0.0.1", "16.0.0.255"], distribution="seq")
        ip_gen_s = ASTFIPGenDist(ip_range=["48.0.0.1", "48.0.0.1"], distribution="seq")
        
        ip_gen = ASTFIPGen(glob=ASTFIPGenGlobal(), dist_client=ip_gen_c, dist_server=ip_gen_s)
        
        return ASTFProfile(default_ip_gen=ip_gen, templates=[template])

# Функция регистрации профиля для TRex
def register():
    return Prof1()