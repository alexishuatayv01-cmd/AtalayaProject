"""Recibe los mensajes de los ESP32, aplica las reglas de alarma y crea los tickets."""
import json
import os
import signal
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import paho.mqtt.client as mqtt
import psycopg

from base import conectar_con_espera

ESPERA_S = int(os.environ["ALARMA_ESPERA_S"])
SIN_COMUNICACION_S = int(os.environ["SIN_COMUNICACION_S"])
SITIO_SIN_CONEXION_S = int(os.environ["SITIO_SIN_CONEXION_S"])
TEMA = "inventor/+/+/evento"
INICIO = time.monotonic()

# Campo del mensaje que indica falla → tipo de alarma.
REGLAS = {"energia": "sin_energia", "red": "sin_red"}
TITULOS = {
    "sin_energia": "sin energía",
    "sin_red": "no responde en la red",
    "sin_comunicacion": "sensor sin comunicación",
}


def abrir_alarma(cur, dispositivo_id, tipo, desde, estado):
    cur.execute(
        """INSERT INTO alarmas (dispositivo_id, tipo, severidad, estado, desde)
           VALUES (%s, %s, 'critica', %s, %s)
           ON CONFLICT (dispositivo_id, tipo) WHERE estado <> 'cerrada' DO NOTHING""",
        (dispositivo_id, tipo, estado, desde),
    )


def cerrar_alarma(cur, dispositivo_id, tipo):
    cur.execute(
        """UPDATE alarmas SET estado = 'cerrada', cerrada_en = now()
           WHERE dispositivo_id = %s AND tipo = %s AND estado <> 'cerrada'""",
        (dispositivo_id, tipo),
    )


def crear_ticket(cur, alarma):
    if alarma.get("sitio_id"):
        cur.execute(
            """INSERT INTO tickets (condominio_id, alarma_id, categoria, titulo, origen, limite)
               SELECT t.condominio_id, %(alarma)s, c.codigo, 'Servidor local sin conexión', 'sensor',
                      now() + c.horas_limite * interval '1 hour'
               FROM sitios t JOIN categorias_sla c ON c.codigo = 'critica'
               WHERE t.id = %(sitio)s""",
            {"alarma": alarma["id"], "sitio": alarma["sitio_id"]},
        )
        return
    cur.execute(
        """INSERT INTO tickets (condominio_id, sistema_id, alarma_id, categoria, titulo, origen, limite)
           SELECT s.condominio_id, s.id, %(alarma)s, c.codigo, s.nombre || ': ' || %(titulo)s, 'sensor',
                  now() + c.horas_limite * interval '1 hour'
           FROM dispositivos d
           JOIN sistemas s ON s.id = d.sistema_id
           JOIN categorias_sla c ON c.codigo = 'critica'
           WHERE d.id = %(dispositivo)s""",
        {"alarma": alarma["id"], "titulo": TITULOS[alarma["tipo"]], "dispositivo": alarma["dispositivo_id"]},
    )
    cur.execute(
        """UPDATE sistemas SET estado = 'falla', actualizado_en = now()
           WHERE id = (SELECT sistema_id FROM dispositivos WHERE id = %s)""",
        (alarma["dispositivo_id"],),
    )


def confirmar_si_duro(cur, dispositivo_id, tipo, hora):
    """Tras un corte, la falla y su fin llegan juntos: si duró lo suficiente, también deja ticket."""
    cur.execute(
        """UPDATE alarmas SET estado = 'activa', activada_en = now()
           WHERE dispositivo_id = %s AND tipo = %s AND estado = 'en_espera'
             AND %s - desde >= make_interval(secs => %s)
           RETURNING id, dispositivo_id, tipo, sitio_id""",
        (dispositivo_id, tipo, hora, ESPERA_S),
    )
    for alarma in cur.fetchall():
        crear_ticket(cur, alarma)


def procesar_mensaje(con, dispositivo_codigo, cuerpo):
    datos = json.loads(cuerpo)
    hora = datetime.fromisoformat(datos["hora"])
    if hora.tzinfo is None:
        raise ValueError("la hora debe indicar su zona horaria")
    with con.transaction(), con.cursor() as cur:
        cur.execute("SELECT id FROM dispositivos WHERE codigo = %s", (dispositivo_codigo,))
        fila = cur.fetchone()
        if not fila:
            print(f"dispositivo desconocido: {dispositivo_codigo}")
            return
        dispositivo_id = fila["id"]
        # El contacto cuenta siempre, también si es un reenvío.
        cur.execute("UPDATE dispositivos SET ultimo_contacto = now() WHERE id = %s", (dispositivo_id,))
        cerrar_alarma(cur, dispositivo_id, "sin_comunicacion")
        cur.execute(
            """INSERT INTO eventos (dispositivo_id, id_mensaje, hora_dispositivo, datos)
               VALUES (%s, %s, %s, %s) ON CONFLICT DO NOTHING""",
            (dispositivo_id, datos["id"], hora, json.dumps(datos.get("datos", {}))),
        )
        if cur.rowcount == 0:
            return  # Mensaje repetido: el ESP32 lo reenvió tras un corte.
        medidas = datos.get("datos", {})
        for campo, tipo in REGLAS.items():
            if campo not in medidas:
                continue
            if medidas[campo]:
                confirmar_si_duro(cur, dispositivo_id, tipo, hora)
                cerrar_alarma(cur, dispositivo_id, tipo)
            else:
                abrir_alarma(cur, dispositivo_id, tipo, hora, "en_espera")
        cur.execute(
            """UPDATE sistemas s SET estado = 'operativo', actualizado_en = now()
               FROM dispositivos d
               WHERE d.sistema_id = s.id AND d.id = %s
                 AND NOT EXISTS (SELECT 1 FROM alarmas a WHERE a.dispositivo_id = d.id AND a.estado = 'activa')""",
            (dispositivo_id,),
        )


def revisar(con):
    """Confirma fallas que duraron lo suficiente y detecta dispositivos que dejaron de hablar."""
    with con.transaction(), con.cursor() as cur:
        # Tras un arranque se da tiempo a los ESP32: el silencio pudo ser del servidor, no de ellos.
        if time.monotonic() - INICIO >= SIN_COMUNICACION_S:
            cur.execute(
                """INSERT INTO alarmas (dispositivo_id, tipo, severidad, estado, desde)
                   SELECT d.id, 'sin_comunicacion', 'critica', 'en_espera', d.ultimo_contacto
                   FROM dispositivos d
                   JOIN sistemas s ON s.id = d.sistema_id
                   LEFT JOIN sitios t ON t.condominio_id = s.condominio_id
                   WHERE d.ultimo_contacto < now() - make_interval(secs => %(com)s)
                     AND (t.id IS NULL OR (t.activo
                          AND t.ultimo_contacto > now() - make_interval(secs => %(sitio)s)
                          AND t.conectado_desde < now() - make_interval(secs => %(com)s)))
                   ON CONFLICT (dispositivo_id, tipo) WHERE estado <> 'cerrada' DO NOTHING""",
                {"com": SIN_COMUNICACION_S, "sitio": SITIO_SIN_CONEXION_S},
            )
            # Si cae el sitio entero se abre una sola alarma, no una por sensor.
            cur.execute(
                """INSERT INTO alarmas (sitio_id, tipo, severidad, estado, desde)
                   SELECT id, 'sitio_sin_conexion', 'critica', 'en_espera', ultimo_contacto
                   FROM sitios
                   WHERE activo AND ultimo_contacto < now() - make_interval(secs => %s)
                   ON CONFLICT (sitio_id, tipo) WHERE estado <> 'cerrada' AND sitio_id IS NOT NULL DO NOTHING""",
                (SITIO_SIN_CONEXION_S,),
            )
        cur.execute(
            """UPDATE alarmas SET estado = 'activa', activada_en = now()
               WHERE estado = 'en_espera'
                 AND (tipo IN ('sin_comunicacion', 'sitio_sin_conexion') OR desde < now() - make_interval(secs => %s))
               RETURNING id, dispositivo_id, tipo, sitio_id""",
            (ESPERA_S,),
        )
        for alarma in cur.fetchall():
            crear_ticket(cur, alarma)
            print(f"alarma activa: {alarma['tipo']} (dispositivo {alarma['dispositivo_id']}, sitio {alarma['sitio_id']})")


def ciclo_reglas():
    con = conectar_con_espera()
    while True:
        try:
            revisar(con)
        except psycopg.Error as error:
            print(f"error en reglas: {error}")
            con = conectar_con_espera()
        time.sleep(5)


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))  # Como proceso 1 ignoraría la señal y Docker tardaría en detenerlo.
    con = conectar_con_espera()
    con.execute(Path("esquema.sql").read_text())
    threading.Thread(target=ciclo_reglas, daemon=True).start()

    def al_conectar(cliente, _datos, _banderas, codigo, _props):
        print(f"conectado a MQTT: {codigo}")
        cliente.subscribe(TEMA, qos=1)

    def al_recibir(_cliente, _datos, mensaje):
        nonlocal con
        partes = mensaje.topic.split("/")
        # El acuse sale al terminar esta función: sin base de datos se espera, no se descarta.
        while True:
            try:
                procesar_mensaje(con, partes[2], mensaje.payload)
                return
            except (psycopg.OperationalError, psycopg.InterfaceError) as error:
                print(f"base de datos no disponible: {error}")
                con = conectar_con_espera()
            except Exception as error:
                print(f"mensaje descartado en {mensaje.topic}: {error}")
                return

    cliente = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="motor", clean_session=False)
    cliente.username_pw_set(os.environ["MQTT_USER"], os.environ["MQTT_PASS"])
    cliente.reconnect_delay_set(min_delay=1, max_delay=5)
    cliente.on_connect = al_conectar
    cliente.on_message = al_recibir
    cliente.connect_async(os.environ["MQTT_HOST"], 1883)
    cliente.loop_forever(retry_first_connection=True)


if __name__ == "__main__":
    print(f"motor iniciado {datetime.now(timezone.utc).isoformat()}")
    main()
