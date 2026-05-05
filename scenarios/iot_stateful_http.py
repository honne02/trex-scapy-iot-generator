# Сценарий Stateful: Эмуляция HTTP-трафика IoT-устройств (Handshake + L7 Data Exchange) для верификации DPI.
from trex.astf.api import *

class Prof1:
    def __init__(self):
        pass

    def get_profile(self, **kwargs):
        # Описываем L7-поведение клиента
        prog_c = ASTFProgram()
        prog_c.send(b"GET /config.json HTTP/1.1\r\nHost: iot-server.local\r\n\r\n")
        prog_c.recv(100) 

        # Описываем L7-поведение сервера
        prog_s = ASTFProgram()
        prog_s.recv(len(b"GET /config.json HTTP/1.1\r\nHost: iot-server.local\r\n\r\n"))
        prog_s.send(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"status\":\"ok\"}")

        # Шаблоны TCP сессии
        temp_c = ASTFTCPClientTemplate(program=prog_c, ip_proto=6, port=80)
        temp_s = ASTFTCPServerTemplate(program=prog_s)
        template = ASTFTemplate(client_template=temp_c, server_template=temp_s)

        # Генератор IP-адресов (имитация пула устройств)
        ip_gen = ASTFIPGen(dist="rand",
                           ip_range=["16.0.0.1", "16.0.0.255"], 
                           distribution="seq")
        
        return ASTFProfile(default_ip_gen=ip_gen, templates=[template])

# Функция регистрации профиля, необходимая для TRex
def register():
    return Prof1()