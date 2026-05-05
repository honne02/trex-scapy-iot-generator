from trex_astf_lib.api import *

class Prof1:
    def __init__(self):
        pass

    def get_profile(self, **kwargs):
        # Описываем поведение клиента (L7 программа)
        prog_c = ASTFProgram()
        prog_c.send(b"GET /config.json HTTP/1.1\r\nHost: iot-server.local\r\n\r\n")
        prog_c.recv(100) # Ожидаем ответ от сервера

        # Описываем поведение сервера
        prog_s = ASTFProgram()
        prog_s.recv(len(b"GET /config.json HTTP/1.1\r\nHost: iot-server.local\r\n\r\n"))
        prog_s.send(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"status\":\"ok\"}")

        # Определяем шаблон (Template)
        # Клиент из подсети 16.0.0.0 стучится на сервер 48.0.0.1
        temp_c = ASTFTCPClientTemplate(program=prog_c, ip_proto=6, port=80)
        temp_s = ASTFTCPServerTemplate(program=prog_s)  # серверная часть
        template = ASTFTemplate(client_template=temp_c, server_template=temp_s)

        # Создаем пул IP-адресов (имитируем масштаб)
        ip_gen = ASTFIPGen(dist="rand",
                           ip_range=["16.0.0.1", "16.0.0.255"], # пулы клиентов
                           distribution="seq")
        
        return ASTFProfile(default_ip_gen=ip_gen, templates=[template])

def register():
    return Prof1()