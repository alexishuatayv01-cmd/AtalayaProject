"""Servidor local: recibe los ESP32, avisa a garita y sube los datos cuando hay internet."""
import html
import json
import os
import sqlite3
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone

import httpx
import paho.mqtt.client as mqtt
import uvicorn
from fastapi import FastAPI
from fastapi.responses import HTMLResponse

RUTA = "/datos/sitio.db"
CODIGO = os.environ["SITIO_CODIGO"]
ESPERA_S = int(os.environ["ALARMA_ESPERA_S"])
SIN_COMUNICACION_S = int(os.environ["SIN_COMUNICACION_S"])
URL = f"{os.environ['GENERAL_URL']}/sitios/{CODIGO}/lote"
TEMA = "inventor/+/+/evento"
LOTE = 200
INICIO = time.monotonic()

REGLAS = {"energia": "sin_energia", "red": "sin_red"}
NOMBRES = {
    "sin_energia": "Sin energía",
    "sin_red": "No responde en la red",
    "sin_comunicacion": "Sensor sin comunicación",
}
estado = {"internet": None, "ultimo_envio": None}


def ahora():
    return datetime.now(timezone.utc)


locales = threading.local()


@contextmanager
def bd():
    # Una conexión abierta por hilo: abrir y cerrar en cada mensaje fuerza escrituras lentas en disco.
    con = getattr(locales, "con", None)
    if con is None:
        con = sqlite3.connect(RUTA, timeout=30)
        con.row_factory = sqlite3.Row
        con.execute("PRAGMA journal_mode=WAL")
        con.execute("PRAGMA synchronous=FULL")
        locales.con = con
    with con:
        yield con


def crear_tablas():
    with bd() as con:
        con.executescript(
            """
            CREATE TABLE IF NOT EXISTS pendientes (
              orden INTEGER PRIMARY KEY AUTOINCREMENT,
              dispositivo TEXT NOT NULL, id_mensaje TEXT NOT NULL,
              hora TEXT NOT NULL, datos TEXT NOT NULL,
              UNIQUE (dispositivo, id_mensaje));
            CREATE TABLE IF NOT EXISTS rechazados (
              dispositivo TEXT, contenido TEXT, motivo TEXT, en TEXT);
            CREATE TABLE IF NOT EXISTS dispositivos (
              codigo TEXT PRIMARY KEY, ultimo_contacto TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS alarmas (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              dispositivo TEXT NOT NULL, tipo TEXT NOT NULL, estado TEXT NOT NULL,
              desde TEXT NOT NULL, activada_en TEXT, cerrada_en TEXT);
            CREATE UNIQUE INDEX IF NOT EXISTS una_abierta
              ON alarmas (dispositivo, tipo) WHERE estado <> 'cerrada';
            """
        )


def validar(cuerpo):
    datos = json.loads(cuerpo)
    if not isinstance(datos, dict) or not isinstance(datos.get("id"), str):
        raise ValueError("falta el id")
    if not isinstance(datos.get("datos"), dict):
        raise ValueError("faltan los datos")
    if datetime.fromisoformat(datos["hora"]).tzinfo is None:
        raise ValueError("la hora debe indicar su zona horaria")
    return datos


def cerrar(con, dispositivo, tipo):
    con.execute(
        "UPDATE alarmas SET estado = 'cerrada', cerrada_en = ? WHERE dispositivo = ? AND tipo = ? AND estado <> 'cerrada'",
        (ahora().isoformat(), dispositivo, tipo),
    )


def guardar(dispositivo, cuerpo):
    try:
        datos = validar(cuerpo)
    except (ValueError, KeyError, TypeError) as error:
        print(f"mensaje rechazado de {dispositivo}: {error}")
        with bd() as con:
            con.execute(
                "INSERT INTO rechazados VALUES (?, ?, ?, ?)",
                (dispositivo, cuerpo.decode(errors="replace"), str(error), ahora().isoformat()),
            )
        return
    with bd() as con:
        con.execute(
            "INSERT INTO dispositivos VALUES (?, ?) ON CONFLICT (codigo) DO UPDATE SET ultimo_contacto = excluded.ultimo_contacto",
            (dispositivo, ahora().isoformat()),
        )
        cerrar(con, dispositivo, "sin_comunicacion")
        nuevo = con.execute(
            "INSERT OR IGNORE INTO pendientes (dispositivo, id_mensaje, hora, datos) VALUES (?, ?, ?, ?)",
            (dispositivo, datos["id"], datos["hora"], json.dumps(datos["datos"])),
        ).rowcount
        if not nuevo:
            return
        for campo, tipo in REGLAS.items():
            if campo not in datos["datos"]:
                continue
            if datos["datos"][campo]:
                cerrar(con, dispositivo, tipo)
            else:
                con.execute(
                    """INSERT OR IGNORE INTO alarmas (dispositivo, tipo, estado, desde)
                       VALUES (?, ?, 'en_espera', ?)""",
                    (dispositivo, tipo, datos["hora"]),
                )


def revisar():
    limite_espera = ahora() - timedelta(seconds=ESPERA_S)
    with bd() as con:
        # Tras un arranque se da tiempo a los ESP32 para volver a reportarse.
        if time.monotonic() - INICIO >= SIN_COMUNICACION_S:
            limite = (ahora() - timedelta(seconds=SIN_COMUNICACION_S)).isoformat()
            con.execute(
                """INSERT OR IGNORE INTO alarmas (dispositivo, tipo, estado, desde, activada_en)
                   SELECT codigo, 'sin_comunicacion', 'activa', ultimo_contacto, ?
                   FROM dispositivos WHERE ultimo_contacto < ?""",
                (ahora().isoformat(), limite),
            )
        for fila in con.execute("SELECT id, desde FROM alarmas WHERE estado = 'en_espera'").fetchall():
            if datetime.fromisoformat(fila["desde"]) < limite_espera:
                con.execute(
                    "UPDATE alarmas SET estado = 'activa', activada_en = ? WHERE id = ?",
                    (ahora().isoformat(), fila["id"]),
                )


def ciclo_revisar():
    while True:
        try:
            revisar()
        except sqlite3.Error as error:
            print(f"error en reglas: {error}")
        time.sleep(5)


def subir_lote(cliente):
    """Devuelve cuántos eventos se enviaron. Solo borra lo que el servidor general confirmó."""
    with bd() as con:
        filas = con.execute(
            "SELECT * FROM pendientes ORDER BY orden LIMIT ?", (LOTE,)
        ).fetchall()
    eventos = [
        {"dispositivo": f["dispositivo"], "id": f["id_mensaje"], "hora": f["hora"], "datos": json.loads(f["datos"])}
        for f in filas
    ]
    respuesta = cliente.post(
        URL, json={"eventos": eventos}, headers={"X-Sitio-Clave": os.environ["SITIO_CLAVE"]}, timeout=30
    )
    respuesta.raise_for_status()
    cuerpo = respuesta.json()
    with bd() as con:
        for dato in cuerpo["confirmados"]:
            con.execute(
                "DELETE FROM pendientes WHERE dispositivo = ? AND id_mensaje = ?", (dato["dispositivo"], dato["id"])
            )
        # Lo rechazado se aparta para revisarlo: no debe trabar la cola.
        for dato in cuerpo["rechazados"]:
            con.execute(
                "INSERT INTO rechazados VALUES (?, ?, 'rechazado por el servidor general', ?)",
                (dato["dispositivo"], dato["id"], ahora().isoformat()),
            )
            con.execute(
                "DELETE FROM pendientes WHERE dispositivo = ? AND id_mensaje = ?", (dato["dispositivo"], dato["id"])
            )
    return len(eventos)


def ciclo_subir():
    with httpx.Client() as cliente:
        while True:
            try:
                enviados = subir_lote(cliente)
                if estado["internet"] is not True:
                    print("conexión con el servidor general: activa")
                estado.update(internet=True, ultimo_envio=ahora().isoformat())
                if enviados == LOTE:
                    continue
            except (httpx.HTTPError, ValueError, KeyError) as error:
                if estado["internet"] is not False:
                    print(f"conexión con el servidor general: perdida ({error})")
                estado["internet"] = False
            except sqlite3.Error as error:
                print(f"error en la cola: {error}")
            time.sleep(5)


def iniciar_mqtt():
    def al_conectar(cliente, _datos, _banderas, codigo, _props):
        print(f"conectado a MQTT: {codigo}")
        cliente.subscribe(TEMA, qos=1)

    def al_recibir(_cliente, _datos, mensaje):
        partes = mensaje.topic.split("/")
        # El acuse sale al terminar esta función: primero debe quedar en disco.
        while True:
            try:
                guardar(partes[2], mensaje.payload)
                return
            except sqlite3.OperationalError as error:
                print(f"cola ocupada: {error}")
                time.sleep(1)
            except Exception as error:
                print(f"mensaje descartado en {mensaje.topic}: {error}")
                return

    cliente = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="sitio", clean_session=False)
    cliente.username_pw_set(os.environ["MQTT_USER"], os.environ["MQTT_PASS"])
    cliente.reconnect_delay_set(min_delay=1, max_delay=5)
    cliente.on_connect = al_conectar
    cliente.on_message = al_recibir
    cliente.connect_async(os.environ["MQTT_HOST"], 1883)
    cliente.loop_start()


app = FastAPI(title="Servidor local")


def leer_estado():
    with bd() as con:
        return {
            "sitio": CODIGO,
            "internet": estado["internet"],
            "ultimo_envio": estado["ultimo_envio"],
            "pendientes": con.execute("SELECT count(*) AS n FROM pendientes").fetchone()["n"],
            "rechazados": con.execute("SELECT count(*) AS n FROM rechazados").fetchone()["n"],
            "alarmas": [
                dict(f)
                for f in con.execute(
                    "SELECT dispositivo, tipo, desde FROM alarmas WHERE estado = 'activa' ORDER BY desde DESC"
                ).fetchall()
            ],
            "dispositivos": [
                dict(f) for f in con.execute("SELECT * FROM dispositivos ORDER BY codigo").fetchall()
            ],
        }


@app.get("/estado")
def ver_estado():
    return leer_estado()


def hora_corta(texto):
    return datetime.fromisoformat(texto).astimezone().strftime("%H:%M:%S") if texto else "—"


@app.get("/", response_class=HTMLResponse)
def pantalla():
    e = leer_estado()
    conexion = {True: "Conectado", False: "Sin internet", None: "Conectando"}[e["internet"]]
    if e["alarmas"]:
        filas = "".join(
            f"<li><strong>{html.escape(NOMBRES.get(a['tipo'], a['tipo']))}</strong>"
            f"<span>{html.escape(a['dispositivo'])} · desde {hora_corta(a['desde'])}</span></li>"
            for a in e["alarmas"]
        )
        alarmas = f'<ul class="alarmas">{filas}</ul>'
    else:
        alarmas = '<p class="calma">Sin alarmas activas</p>'
    equipos = "".join(
        f"<tr><td>{html.escape(d['codigo'])}</td><td>{hora_corta(d['ultimo_contacto'])}</td></tr>"
        for d in e["dispositivos"]
    ) or '<tr><td colspan="2">Todavía no se ha reportado ningún sensor</td></tr>'
    return f"""<!doctype html><html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="5"><title>Garita · {html.escape(CODIGO)}</title>
<style>
body{{margin:0;padding:20px;background:#11191d;color:#e6eef0;font:18px/1.4 system-ui,sans-serif}}
h1{{font-size:24px;margin:0 0 4px}} h2{{font-size:18px;margin:24px 0 8px}}
.barra{{color:#a0b2b9;font-size:16px}} .off{{color:#f2aa5c;font-weight:600}} .on{{color:#54c0c9;font-weight:600}}
.alarmas{{list-style:none;margin:0;padding:0;display:grid;gap:8px}}
.alarmas li{{background:#5a1d1d;border-left:6px solid #ff6b5e;padding:14px}}
.alarmas strong{{display:block;font-size:22px}} .alarmas span{{color:#f3d3cf}}
.calma{{background:#17322f;border-left:6px solid #54c0c9;padding:14px;margin:0;font-size:22px}}
table{{border-collapse:collapse;width:100%}} td{{padding:6px 0;border-bottom:1px solid #33444b}}
</style></head><body>
<h1>Pantalla de garita</h1>
<p class="barra"><span class="{'on' if e['internet'] else 'off'}">{conexion}</span> · Pendientes por subir: {e['pendientes']}</p>
<h2>Alarmas</h2>{alarmas}
<h2>Sensores: último reporte</h2><table>{equipos}</table>
</body></html>"""


if __name__ == "__main__":
    crear_tablas()
    threading.Thread(target=ciclo_revisar, daemon=True).start()
    threading.Thread(target=ciclo_subir, daemon=True).start()
    iniciar_mqtt()
    uvicorn.run(app, host="0.0.0.0", port=8100, log_level="warning")
