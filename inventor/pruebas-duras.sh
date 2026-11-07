#!/bin/bash
# Pruebas de resistencia del servidor. Solo usa el condominio de prueba.
cd /mnt/DATOS/servidor/inventor
. ./.env
C="X-Api-Key: $API_KEY"; A=127.0.0.1:8000
sim() { docker compose run --rm -T simulador python simulador.py "$@" >/dev/null 2>&1; }
sql() { docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -c "$1"; }
ok() { echo "PASA  $1"; }; mal() { echo "FALLA $1 → $2"; FALLOS=1; }
FALLOS=0
pub() { docker run --rm --network host eclipse-mosquitto:2 mosquitto_pub -h 127.0.0.1 -p 1883 -q 1 "$@"; }

echo "== Endpoints de la API"
for r in salud condominios sistemas alarmas tickets "eventos?dispositivo=esp32-cam-02"; do
  c=$(curl -s -o /dev/null -w '%{http_code}' -H "$C" "$A/$r"); [ "$c" = 200 ] && ok "/$r" || mal "/$r" "$c"
done
c=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "$C" -H 'Content-Type: application/json' -d '{"estado":"inventado"}' $A/tickets/1); [ "$c" = 422 ] && ok "estado inválido rechazado" || mal "estado inválido" "$c"

echo "== Entrada por el puerto real, como un ESP32"
ID=puerto-$(date +%s); H=$(date -u +%FT%TZ)
pub -u "$MQTT_USER" -P "$MQTT_PASS" -t inventor/prueba/esp32-cam-02/evento -m "{\"id\":\"$ID\",\"hora\":\"$H\",\"datos\":{\"energia\":true,\"red\":true}}"; sleep 2
[ "$(sql "SELECT count(*) FROM eventos WHERE id_mensaje='$ID'")" = 1 ] && ok "mensaje por 127.0.0.1:1883 con clave" || mal "puerto real" "no llegó"
pub -u "$MQTT_USER" -P clave-mala -t x -m y >/dev/null 2>&1 && mal "clave incorrecta" "aceptada" || ok "clave incorrecta rechazada"
pub -u "$MQTT_USER" -P "$MQTT_PASS" -t inventor/prueba/esp32-cam-02/evento -m 'esto no es json'
pub -u "$MQTT_USER" -P "$MQTT_PASS" -t inventor/prueba/esp32-cam-02/evento -m '[1,2]' 
pub -u "$MQTT_USER" -P "$MQTT_PASS" -t inventor/prueba/desconocido/evento -m "{\"id\":\"x\",\"hora\":\"$H\",\"datos\":{}}"; sleep 2
ID2=tras-basura-$(date +%s)
pub -u "$MQTT_USER" -P "$MQTT_PASS" -t inventor/prueba/esp32-cam-02/evento -m "{\"id\":\"$ID2\",\"hora\":\"$H\",\"datos\":{\"energia\":true}}"; sleep 2
[ "$(sql "SELECT count(*) FROM eventos WHERE id_mensaje='$ID2'")" = 1 ] && ok "mensajes dañados o desconocidos no lo tumban" || mal "mensaje dañado" "dejó de recibir"

echo "== Ráfaga de 2000 mensajes"
ANTES=$(sql "SELECT count(*) FROM eventos"); INI=$(date +%s)
docker compose run --rm -T simulador python simulador.py --veces 2000 --intervalo 0 >/dev/null 2>&1; PUB=$(( $(date +%s)-INI ))
for i in $(seq 1 120); do
  DESP=$(sql "SELECT count(*) FROM eventos"); N=$((DESP-ANTES)); [ "$N" -ge 2000 ] && break; sleep 3
done
T=$(( $(date +%s)-INI )); echo "      publicados en $PUB s; guardados $N en $T s ($((N/(T>0?T:1))) por segundo)"
[ "$N" = 2000 ] && ok "no se perdió ninguno" || mal "ráfaga" "$N de 2000"

echo "== Base de datos caída 20 s con mensajes entrando"
ID3=bd-caida-$(date +%s)
docker compose stop db >/dev/null 2>&1; sleep 3
c=$(curl -s -o /dev/null -m 5 -w '%{http_code}' $A/salud); echo "      /salud con la base caída: $c"
pub -u "$MQTT_USER" -P "$MQTT_PASS" -t inventor/prueba/esp32-cam-02/evento -m "{\"id\":\"$ID3\",\"hora\":\"$H\",\"datos\":{\"energia\":true}}"
sleep 17; docker compose start db >/dev/null 2>&1; sleep 15
[ "$(sql "SELECT count(*) FROM eventos WHERE id_mensaje='$ID3'")" = 1 ] && ok "el mensaje enviado durante la caída no se pierde" || mal "base caída" "mensaje perdido"
[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' $A/salud)" = 200 ] && ok "la API se recupera sola" || mal "API" "no volvió"
ID4=bd-despues-$(date +%s)
pub -u "$MQTT_USER" -P "$MQTT_PASS" -t inventor/prueba/esp32-cam-02/evento -m "{\"id\":\"$ID4\",\"hora\":\"$H\",\"datos\":{\"energia\":true}}"; sleep 3
[ "$(sql "SELECT count(*) FROM eventos WHERE id_mensaje='$ID4'")" = 1 ] && ok "el motor sigue recibiendo después" || mal "motor" "no recibe tras la caída"

echo "== MQTT caído 15 s"
ID6=mqtt-encolado-$(date +%s)
docker compose stop mqtt >/dev/null 2>&1; sleep 15; docker compose start mqtt >/dev/null 2>&1; sleep 10
ID5=mqtt-despues-$(date +%s)
pub -u "$MQTT_USER" -P "$MQTT_PASS" -t inventor/prueba/esp32-cam-02/evento -m "{\"id\":\"$ID5\",\"hora\":\"$H\",\"datos\":{\"energia\":true}}"; sleep 3
[ "$(sql "SELECT count(*) FROM eventos WHERE id_mensaje='$ID5'")" = 1 ] && ok "el motor se reconecta solo" || mal "reconexión" "no se reconectó"

echo "== Servicio que se cae solo"
for s in motor api mqtt db; do
  n=inventor-$s-1; R0=$(docker inspect -f '{{.RestartCount}}' $n)
  # PostgreSQL con SIGTERM espera a que se vayan los clientes; SIGQUIT es su parada brusca, como una caída real.
  S=TERM; [ $s = db ] && S=QUIT
  docker exec $n sh -c "kill -$S 1" >/dev/null 2>&1
  for i in $(seq 1 20); do sleep 2; R1=$(docker inspect -f '{{.RestartCount}}' $n); E=$(docker inspect -f '{{.State.Status}}' $n); [ "$R1" -gt "$R0" ] && [ "$E" = running ] && break; done
  [ "$R1" -gt "$R0" ] && [ "$E" = running ] && ok "$s se cayó y volvió solo (reinicios $R0 → $R1)" || mal "$s" "reinicios $R0 → $R1, estado $E"
done
sleep 15
ID7=tras-caidas-$(date +%s)
pub -u "$MQTT_USER" -P "$MQTT_PASS" -t inventor/prueba/esp32-cam-02/evento -m "{\"id\":\"$ID7\",\"hora\":\"$H\",\"datos\":{\"energia\":true}}"; sleep 3
[ "$(sql "SELECT count(*) FROM eventos WHERE id_mensaje='$ID7'")" = 1 ] && ok "todo sigue recibiendo después de las caídas" || mal "tras caídas" "mensaje no llegó"
[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' $A/salud)" = 200 ] && ok "la API responde después de las caídas" || mal "API" "no responde"

echo "== Estado final"
docker compose ps --format '{{.Service}}: {{.Status}}'
docker stats --no-stream --format '{{.Name}}: cpu {{.CPUPerc}} ram {{.MemUsage}}'
echo; [ $FALLOS = 0 ] && echo "RESULTADO: TODO PASA" || echo "RESULTADO: HAY FALLAS"
