#!/bin/bash
# Pruebas del servidor local con cortes reales de red. Solo toca el condominio prueba-sitio.
cd /mnt/DATOS/servidor/inventor
. ./.env
CLAVE=$(grep ^SITIO_CLAVE= sitio/.env | cut -d= -f2)
L=127.0.0.1:8100; COND=prueba-sitio; D1=esp32-sitio-01; D2=esp32-sitio-02; CONT=sitio-prueba-sitio-1
ds() { docker compose -f sitio/compose.yaml "$@"; }
sim() { ds run --rm -T simulador python simulador.py --condominio $COND "$@" >/dev/null 2>&1; }
sql() { docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -c "$1"; }
est() { curl -s -m 5 $L/estado | python3 -c "import json,sys;d=json.load(sys.stdin);print($1)"; }
ok() { echo "PASA  $1"; }; mal() { echo "FALLA $1 → $2"; FALLOS=1; }
si() { [ "$2" = "$3" ] && ok "$1" || mal "$1" "esperaba $3, hay $2"; }
FALLOS=0
FILTRO="d.codigo IN ('$D1','$D2')"
ev() { sql "SELECT count(*) FROM eventos e JOIN dispositivos d ON d.id=e.dispositivo_id WHERE $FILTRO"; }
tk() { sql "SELECT count(*) FROM tickets t JOIN condominios c ON c.id=t.condominio_id WHERE c.codigo='$COND' AND t.titulo LIKE '%$1%'"; }
vaciar() { for i in $(seq 1 ${1:-40}); do [ "$(est "d['pendientes']")" = 0 ] && return 0; sleep 3; done; return 1; }
limpiar_general() { sql "DELETE FROM tickets WHERE condominio_id=(SELECT id FROM condominios WHERE codigo='$COND');
 DELETE FROM alarmas WHERE sitio_id=(SELECT id FROM sitios WHERE codigo='$COND') OR dispositivo_id IN (SELECT id FROM dispositivos d WHERE $FILTRO);
 DELETE FROM eventos WHERE dispositivo_id IN (SELECT id FROM dispositivos d WHERE $FILTRO);" >/dev/null; }

docker network connect internet-sim $CONT 2>/dev/null
ds up -d >/dev/null 2>&1; sleep 8
sim --dispositivo $D1; sim --dispositivo $D2; vaciar; sleep 6
limpiar_general

echo "== A. Con internet"
sim --dispositivo $D1 --veces 3 --intervalo 0; sleep 8
si "los 3 mensajes llegan al servidor general" "$(ev)" 3
si "la cola local queda vacía" "$(est "d['pendientes']")" 0

echo "== B. Corte de internet con una falla durante el corte"
docker network disconnect internet-sim $CONT; CORTE=$(date +%s); BASE=$(ev)
sim --dispositivo $D2 --veces 2 --intervalo 0
sim --dispositivo $D1 --energia no --veces 7 --intervalo 6; sleep 8
si "garita ve que no hay internet" "$(est "d['internet']")" False
si "garita ve la alarma sin internet" "$(est "sum(a['tipo']=='sin_energia' for a in d['alarmas'])")" 1
si "los datos esperan en la cola" "$(est "d['pendientes']")" 9
si "el general todavía no tiene esos datos" "$(ev)" "$BASE"

echo "== C. Reinicio del servidor local durante el corte"
docker restart $CONT >/dev/null; sleep 6
si "la cola sobrevive al reinicio" "$(est "d['pendientes']")" 9
si "la alarma sobrevive al reinicio" "$(est "sum(a['tipo']=='sin_energia' for a in d['alarmas'])")" 1
sim --dispositivo $D1 --energia si; sleep 3
si "la energía vuelve durante el corte y garita lo ve" "$(est "sum(a['tipo']=='sin_energia' for a in d['alarmas'])")" 0
si "ese mensaje también queda en cola" "$(est "d['pendientes']")" 10

echo "== D. El general detecta el sitio caído"
R=$(( 75 - ($(date +%s) - CORTE) )); [ $R -gt 0 ] && sleep $R
si "una sola alarma de sitio sin conexión" "$(tk 'Servidor local sin conexión')" 1
si "ningún ticket falso por sensor callado" "$(tk 'sin comunicación')" 0
si "la falla del corte aún no generó ticket" "$(tk 'sin energía')" 0

echo "== E. Vuelve internet"
docker network connect internet-sim $CONT
vaciar && ok "la cola se vacía sola" || mal "cola" "$(est "d['pendientes']") pendientes"
si "llegaron los 10 exactos, sin perder ni duplicar" "$(( $(ev) - BASE ))" 10
si "garita vuelve a ver conexión" "$(est "d['internet']")" True
sleep 6
si "se cierra la alarma de sitio" "$(sql "SELECT count(*) FROM alarmas WHERE tipo='sitio_sin_conexion' AND estado<>'cerrada'")" 0
si "la falla ocurrida en el corte deja su ticket" "$(tk 'sin energía')" 1
si "su alarma queda cerrada, con la energía de vuelta" "$(sql "SELECT count(*) FROM alarmas a JOIN dispositivos d ON d.id=a.dispositivo_id WHERE a.tipo='sin_energia' AND a.estado<>'cerrada' AND $FILTRO")" 0
echo "      inicio de la falla: $(sql "SELECT a.desde::time(0) FROM alarmas a JOIN dispositivos d ON d.id=a.dispositivo_id WHERE a.tipo='sin_energia' AND $FILTRO ORDER BY a.id DESC LIMIT 1") UTC; reporte recibido: $(sql "SELECT t.creado_en::time(0) FROM tickets t WHERE t.titulo LIKE '%sin energía%' ORDER BY t.id DESC LIMIT 1") UTC"

echo "== F. Seguridad y duplicados"
U=$A; API=127.0.0.1:8000/sitios/$COND/lote; J='Content-Type: application/json'
si "clave incorrecta rechazada" "$(curl -s -o /dev/null -w '%{http_code}' -H "$J" -H 'X-Sitio-Clave: mala' -d '{"eventos":[]}' $API)" 401
H=$(date -u +%FT%TZ); N=$(ev); M="{\"eventos\":[{\"dispositivo\":\"$D1\",\"id\":\"dup-$(date +%s)\",\"hora\":\"$H\",\"datos\":{\"energia\":true}}]}"
curl -s -o /dev/null -H "$J" -H "X-Sitio-Clave: $CLAVE" -d "$M" $API; curl -s -o /dev/null -H "$J" -H "X-Sitio-Clave: $CLAVE" -d "$M" $API
si "confirmación perdida y reenvío: se guarda una vez" "$(( $(ev) - N ))" 1
R=$(curl -s -H "$J" -H "X-Sitio-Clave: $CLAVE" -d "{\"eventos\":[{\"dispositivo\":\"esp32-cam-02\",\"id\":\"ajeno\",\"hora\":\"$H\",\"datos\":{}}]}" $API | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["rechazados"]))')
si "un sitio no puede enviar sensores de otro condominio" "$R" 1
R=$(curl -s -H "$J" -H "X-Sitio-Clave: $CLAVE" -d "{\"eventos\":[{\"dispositivo\":\"$D1\",\"id\":\"sin-zona\",\"hora\":\"2026-11-02T10:00:00\",\"datos\":{}},{\"dispositivo\":\"$D1\",\"id\":\"sano-$(date +%s)\",\"hora\":\"$H\",\"datos\":{}}]}" $API | python3 -c 'import json,sys;d=json.load(sys.stdin);print(len(d["rechazados"]),len(d["confirmados"]))')
si "un dato dañado no traba el lote" "$R" "1 1"
docker run --rm --network host eclipse-mosquitto:2 mosquitto_pub -h 127.0.0.1 -p 1884 -q 1 -u esp32 -P "$(grep ^MQTT_PASS= sitio/.env | cut -d= -f2)" -t inventor/$COND/$D1/evento -m 'esto no es json'; sleep 2
sim --dispositivo $D1 ; sleep 2
[ "$(est "d['rechazados']")" -ge 1 ] && ok "mensaje dañado apartado en el sitio, sin frenarlo" || mal "mensaje dañado" "no apartado"
docker run --rm --network host eclipse-mosquitto:2 mosquitto_pub -h 127.0.0.1 -p 1884 -u intruso -P mala -t x -m y >/dev/null 2>&1 && mal "MQTT local" "acepta clave mala" || ok "MQTT local rechaza clave incorrecta"

echo "== G. Servidor general caído"
docker compose stop api >/dev/null 2>&1; sleep 7
sim --dispositivo $D2 --veces 5 --intervalo 0; sleep 3; N=$(est "d['pendientes']")
si "guarda en cola con el general caído" "$N" 5
docker compose start api >/dev/null 2>&1
vaciar && ok "al volver el general se vacía la cola" || mal "cola" "no se vació"

echo "== H. Ráfaga tras un corte largo (2000 mensajes)"
docker network disconnect internet-sim $CONT; N=$(ev)
ds run --rm -T simulador python simulador.py --condominio $COND --dispositivo $D2 --veces 2000 --intervalo 0 >/dev/null 2>&1; sleep 5
for i in $(seq 1 40); do P=$(est "d['pendientes']"); [ "$P" = 2000 ] && break; sleep 3; done
si "la cola local guarda los 2000" "$P" 2000
INI=$(date +%s); docker network connect internet-sim $CONT
vaciar 60 && T=$(( $(date +%s)-INI )) && echo "      subidos en $T s"
si "llegan los 2000 al general" "$(( $(ev) - N ))" 2000

echo "== I. Sensor realmente callado con el sitio conectado ($SIN_COMUNICACION_S s)"
sim --dispositivo $D1; sim --dispositivo $D2; T0=$(tk 'sin comunicación')
sleep $(( SIN_COMUNICACION_S + 20 ))
si "garita lo ve en la pantalla" "$(est "sum(a['tipo']=='sin_comunicacion' for a in d['alarmas'])")" 2
si "el general crea sus tickets" "$(( $(tk 'sin comunicación') - T0 ))" 2
sim --dispositivo $D1; sim --dispositivo $D2; sleep 8
si "se cierran al volver en el sitio" "$(est "sum(a['tipo']=='sin_comunicacion' for a in d['alarmas'])")" 0
si "se cierran al volver en el general" "$(sql "SELECT count(*) FROM alarmas a JOIN dispositivos d ON d.id=a.dispositivo_id WHERE a.tipo='sin_comunicacion' AND a.estado<>'cerrada' AND $FILTRO")" 0

echo; ds ps --format '{{.Service}}: {{.Status}}'
docker logs $CONT --tail 200 2>&1 | grep -ciE 'traceback|descartado' | sed 's/^/errores graves en el log del sitio: /'
docker compose logs api motor --no-log-prefix --tail 400 2>&1 | grep -ciE 'traceback' | sed 's/^/errores graves en el log del general: /'
[ $FALLOS = 0 ] && echo "RESULTADO: TODO PASA" || echo "RESULTADO: HAY FALLAS"
