"""API del servidor general. La usarán la web y la app."""
import hashlib
import json
import os
import secrets
from datetime import datetime, timedelta, timezone

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel

from base import conectar
from motor import SITIO_SIN_CONEXION_S, procesar_mensaje

app = FastAPI(title="Inventor Technology")
ESTADOS = {"pendiente", "no_resuelto", "resuelto"}


def validar_clave(x_api_key: str = Header(default="")):
    if not secrets.compare_digest(x_api_key, os.environ["API_KEY"]):
        raise HTTPException(status_code=401, detail="Clave de API incorrecta")


def consultar(sql, parametros=()):
    with conectar() as con:
        return con.execute(sql, parametros).fetchall()


@app.get("/salud")
def salud():
    consultar("SELECT 1")
    return {"estado": "ok"}


@app.get("/condominios", dependencies=[Depends(validar_clave)])
def condominios():
    return consultar("SELECT * FROM condominios ORDER BY nombre")


@app.get("/sistemas", dependencies=[Depends(validar_clave)])
def sistemas(condominio_id: int | None = None):
    return consultar(
        "SELECT * FROM sistemas WHERE %(c)s::int IS NULL OR condominio_id = %(c)s ORDER BY nombre",
        {"c": condominio_id},
    )


@app.get("/alarmas", dependencies=[Depends(validar_clave)])
def alarmas(abiertas: bool = False):
    return consultar(
        "SELECT * FROM alarmas WHERE NOT %s OR estado <> 'cerrada' ORDER BY desde DESC LIMIT 200",
        (abiertas,),
    )


@app.get("/eventos", dependencies=[Depends(validar_clave)])
def eventos(dispositivo: str, limite: int = 100):
    return consultar(
        """SELECT e.* FROM eventos e JOIN dispositivos d ON d.id = e.dispositivo_id
           WHERE d.codigo = %s ORDER BY e.hora_dispositivo DESC LIMIT %s""",
        (dispositivo, min(limite, 1000)),
    )


@app.get("/tickets", dependencies=[Depends(validar_clave)])
def tickets():
    # Primero los vencidos, para que tomen prioridad.
    return consultar("SELECT * FROM tickets_sla ORDER BY sla_rojo DESC, limite ASC LIMIT 200")


class TicketNuevo(BaseModel):
    condominio_id: int
    sistema_id: int | None = None
    categoria: str
    titulo: str
    limite: datetime | None = None


@app.post("/tickets", status_code=201, dependencies=[Depends(validar_clave)])
def crear_ticket(ticket: TicketNuevo):
    categoria = consultar("SELECT horas_limite FROM categorias_sla WHERE codigo = %s", (ticket.categoria,))
    if not categoria:
        raise HTTPException(status_code=422, detail="Categoría desconocida")
    limite = ticket.limite or datetime.now(timezone.utc) + timedelta(hours=float(categoria[0]["horas_limite"]))
    return consultar(
        """INSERT INTO tickets (condominio_id, sistema_id, categoria, titulo, origen, limite)
           VALUES (%s, %s, %s, %s, 'manual', %s) RETURNING *""",
        (ticket.condominio_id, ticket.sistema_id, ticket.categoria, ticket.titulo, limite),
    )[0]


class CambioEstado(BaseModel):
    estado: str


@app.patch("/tickets/{ticket_id}", dependencies=[Depends(validar_clave)])
def cambiar_estado(ticket_id: int, cambio: CambioEstado):
    if cambio.estado not in ESTADOS:
        raise HTTPException(status_code=422, detail="Estado desconocido")
    filas = consultar(
        """UPDATE tickets SET estado = %(e)s,
             resuelto_en = CASE WHEN %(e)s = 'resuelto' THEN now() END
           WHERE id = %(i)s RETURNING *""",
        {"e": cambio.estado, "i": ticket_id},
    )
    if not filas:
        raise HTTPException(status_code=404, detail="Ticket no encontrado")
    return filas[0]


class Lote(BaseModel):
    eventos: list[dict] = []


@app.post("/sitios/{codigo}/lote")
def recibir_lote(codigo: str, lote: Lote, x_sitio_clave: str = Header(default="")):
    """Recibe los datos de un servidor local. Un lote vacío solo avisa que sigue conectado."""
    resumen = hashlib.sha256(x_sitio_clave.encode()).hexdigest()
    confirmados, rechazados = [], []
    with conectar() as con:
        sitio = con.execute("SELECT * FROM sitios WHERE codigo = %s AND activo", (codigo,)).fetchone()
        if not sitio or not secrets.compare_digest(resumen, sitio["clave_sha256"]):
            raise HTTPException(status_code=401, detail="Sitio o clave incorrectos")
        permitidos = {
            f["codigo"]
            for f in con.execute(
                """SELECT d.codigo FROM dispositivos d JOIN sistemas s ON s.id = d.sistema_id
                   WHERE s.condominio_id = %s""",
                (sitio["condominio_id"],),
            ).fetchall()
        }
        # Todo el lote se guarda junto: la confirmación sale solo si quedó en la base.
        with con.transaction():
            con.execute(
                """UPDATE sitios SET ultimo_contacto = now(),
                     conectado_desde = CASE
                       WHEN ultimo_contacto IS NULL OR ultimo_contacto < now() - make_interval(secs => %s)
                       THEN now() ELSE conectado_desde END
                   WHERE id = %s""",
                (SITIO_SIN_CONEXION_S, sitio["id"]),
            )
            con.execute(
                """UPDATE alarmas SET estado = 'cerrada', cerrada_en = now()
                   WHERE sitio_id = %s AND tipo = 'sitio_sin_conexion' AND estado <> 'cerrada'""",
                (sitio["id"],),
            )
            for evento in lote.eventos:
                dato = {"dispositivo": evento.get("dispositivo"), "id": evento.get("id")}
                if evento.get("dispositivo") not in permitidos:
                    rechazados.append(dato)
                    continue
                try:
                    procesar_mensaje(con, evento["dispositivo"], json.dumps(evento))
                    confirmados.append(dato)
                except (ValueError, KeyError, TypeError) as error:
                    print(f"evento rechazado de {codigo}: {error}")
                    rechazados.append(dato)
    return {"confirmados": confirmados, "rechazados": rechazados}
