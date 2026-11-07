#!/bin/bash
# Pruebas de punta a punta del paso 1. Solo toca el condominio de prueba.
cd /mnt/DATOS/servidor/inventor
. ./.env
C="X-Api-Key: $API_KEY"; A=127.0.0.1:8000
sim() { docker compose run --rm -T simulador python simulador.py "$@" >/dev/null 2>&1; }
sql() { docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -c "$1"; }
ok() { echo "PASA  $1"; }; mal() { echo "FALLA $1 → $2"; FALLOS=1; }
FALLOS=0
docker compose up -d >/dev/null 2>&1; sleep 10
sim; sleep 7  # Sensor al día: evita una alarma legítima de «sin comunicación» durante la prueba.
sql "DELETE FROM tickets; DELETE FROM alarmas; DELETE FROM eventos;" >/dev/null

echo "== Seguridad"
[ "$(curl -s -o /dev/null -w '%{http_code}' $A/tickets)" = 401 ] && ok "API sin clave rechazada" || mal "API sin clave" "aceptada"
docker compose exec -T mqtt mosquitto_pub -h localhost -t x -m y >/dev/null 2>&1 && mal "MQTT anónimo" "aceptado" || ok "MQTT anónimo rechazado"

echo "== Falla breve no alarma"
sim --energia no; sleep 1; sim --energia si; sleep 8
N=$(sql "SELECT count(*) FROM tickets"); [ "$N" = 0 ] && ok "una falla de segundos no crea ticket" || mal "falla breve" "$N tickets"

echo "== Mensaje repetido"
sim --repetir-id repetido-1; sim --repetir-id repetido-1; sleep 2
N=$(sql "SELECT count(*) FROM eventos WHERE id_mensaje='repetido-1'"); [ "$N" = 1 ] && ok "reenvío guardado una sola vez" || mal "reenvío" "$N copias"

echo "== 1. Cámara sin energía"
sim --energia no --veces 9 --intervalo 5; sleep 8
sql "SELECT 'alarma: '||tipo||' / '||severidad||' / '||estado FROM alarmas WHERE tipo='sin_energia'"
sql "SELECT 'ticket: '||titulo||' / '||categoria||' / '||estado||' / vence en '||round(extract(epoch FROM limite-creado_en)/3600)||' h' FROM tickets"
[ "$(sql "SELECT count(*) FROM alarmas WHERE tipo='sin_energia' AND estado='activa'")" = 1 ] && ok "alarma crítica activa" || mal "alarma" "no activa"
[ "$(sql "SELECT count(*) FROM tickets WHERE categoria='critica' AND origen='sensor'")" = 1 ] && ok "un solo ticket automático" || mal "ticket" "cantidad incorrecta"
[ "$(curl -s -H "$C" $A/sistemas | grep -c '"estado":"falla"')" = 1 ] && ok "la API muestra el sistema en falla" || mal "estado sistema" "no marcado"
sim --energia si; sleep 3
[ "$(sql "SELECT estado FROM alarmas WHERE tipo='sin_energia' ORDER BY id DESC LIMIT 1")" = cerrada ] && ok "alarma se cierra al volver la energía" || mal "recuperación" "sigue abierta"
[ "$(sql "SELECT estado FROM tickets LIMIT 1")" = pendiente ] && ok "el ticket sigue pendiente hasta que lo cierre una persona" || mal "ticket" "cambió solo"

echo "== 2. Sensor que deja de hablar ($SIN_COMUNICACION_S s)"
sleep $((SIN_COMUNICACION_S + 12))
[ "$(sql "SELECT count(*) FROM alarmas WHERE tipo='sin_comunicacion' AND estado='activa'")" = 1 ] && ok "aparece «sin comunicación» con ticket" || mal "sin comunicación" "no apareció"
sim; sleep 3
[ "$(sql "SELECT count(*) FROM alarmas WHERE tipo='sin_comunicacion' AND estado<>'cerrada'")" = 0 ] && ok "se cierra cuando vuelve a hablar" || mal "sin comunicación" "sigue abierta"

echo "== 3. SLA en rojo"
CID=$(sql "SELECT id FROM condominios WHERE codigo='prueba'")
LIM=$(date -u -d '+4 seconds' +%FT%TZ)
TID=$(curl -s -H "$C" -H 'Content-Type: application/json' -d "{\"condominio_id\":$CID,\"categoria\":\"baja\",\"titulo\":\"Prueba SLA\",\"limite\":\"$LIM\"}" $A/tickets | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
[ "$(sql "SELECT sla_rojo FROM tickets_sla WHERE id=$TID")" = f ] && ok "dentro de plazo: no está en rojo" || mal "SLA" "rojo antes de tiempo"
sleep 6
[ "$(sql "SELECT sla_rojo FROM tickets_sla WHERE id=$TID")" = t ] && ok "vencido: pasa a rojo" || mal "SLA" "no pasó a rojo"
curl -s -H "$C" $A/tickets | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if d[0]["sla_rojo"] and d[0]["titulo"]=="Prueba SLA" else 1)' && ok "el vencido sale primero en la lista" || mal "prioridad" "no sale primero"
curl -s -o /dev/null -X PATCH -H "$C" -H 'Content-Type: application/json' -d '{"estado":"resuelto"}' $A/tickets/$TID
[ "$(sql "SELECT sla_rojo FROM tickets_sla WHERE id=$TID")" = f ] && ok "resuelto: sale de rojo" || mal "SLA" "sigue en rojo"

echo "== 4. Reinicio de servicios"
ANTES=$(sql "SELECT count(*) FROM eventos")/$(sql "SELECT count(*) FROM tickets")
docker compose down >/dev/null 2>&1; docker compose up -d >/dev/null 2>&1; sleep 15
DESPUES=$(sql "SELECT count(*) FROM eventos")/$(sql "SELECT count(*) FROM tickets")
[ "$ANTES" = "$DESPUES" ] && ok "datos intactos tras reiniciar ($DESPUES eventos/tickets)" || mal "persistencia" "$ANTES → $DESPUES"
sim; sleep 3
[ "$(sql "SELECT count(*) FROM eventos")/$(sql "SELECT count(*) FROM tickets")" != "$ANTES" ] && ok "sigue recibiendo mensajes tras reiniciar" || mal "motor" "no recibe"

echo "== Mensajes con el motor detenido"
docker compose stop motor >/dev/null 2>&1
sim --repetir-id en-pausa; sleep 2
docker compose start motor >/dev/null 2>&1; sleep 8
[ "$(sql "SELECT count(*) FROM eventos WHERE id_mensaje='en-pausa'")" = 1 ] && ok "lo recibido con el motor detenido no se pierde" || mal "cola" "mensaje perdido"
docker compose ps --format '{{.Service}}: {{.Status}}'

echo "== 5. Respaldo y restauración"
./respaldo.sh
ULT=$(ls -t ~/respaldos-inventor/base-*.dump | head -1)
ORIG=$(sql "SELECT count(*) FROM eventos")/$(sql "SELECT count(*) FROM tickets")
docker compose exec -T db sh -c 'createdb -U "$POSTGRES_USER" restaurada'
docker compose exec -T db sh -c 'pg_restore -U "$POSTGRES_USER" -d restaurada' < "$ULT"
REST=$(docker compose exec -T db sh -c 'psql -U "$POSTGRES_USER" -d restaurada -At -c "SELECT (SELECT count(*) FROM eventos)||chr(47)||(SELECT count(*) FROM tickets)"')
docker compose exec -T db sh -c 'dropdb -U "$POSTGRES_USER" restaurada'
[ "$ORIG" = "$REST" ] && ok "la copia restaurada coincide ($REST)" || mal "restauración" "$ORIG vs $REST"

echo "== Dónde quedó todo"
docker compose exec -T db sh -c 'df -h /var/lib/postgresql/data | tail -1'
ss -tln | grep -E ':(1883|8000)\b'
echo; [ $FALLOS = 0 ] && echo "RESULTADO: TODO PASA" || echo "RESULTADO: HAY FALLAS"
