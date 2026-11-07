"""ESP32 virtual: publica los mismos mensajes que publicará el real."""
import argparse
import json
import os
import time
import uuid
from datetime import datetime, timezone

import paho.mqtt.client as mqtt


def main():
    p = argparse.ArgumentParser(add_help=False)
    p.add_argument("--ayuda", action="help")
    p.add_argument("--condominio", default="prueba")
    p.add_argument("--dispositivo", default="esp32-cam-02")
    p.add_argument("--energia", choices=["si", "no"], default="si")
    p.add_argument("--red", choices=["si", "no"], default="si")
    p.add_argument("--veces", type=int, default=1)
    p.add_argument("--intervalo", type=float, default=5)
    p.add_argument("--repetir-id", default=None, help="reenvía un mensaje con este id")
    a = p.parse_args()

    cliente = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    cliente.username_pw_set(os.environ["MQTT_USER"], os.environ["MQTT_PASS"])
    cliente.connect(os.environ["MQTT_HOST"], 1883)
    cliente.loop_start()
    tema = f"inventor/{a.condominio}/{a.dispositivo}/evento"
    for i in range(a.veces):
        mensaje = {
            "id": a.repetir_id or uuid.uuid4().hex,
            "hora": datetime.now(timezone.utc).isoformat(),
            "datos": {"energia": a.energia == "si", "red": a.red == "si"},
        }
        cliente.publish(tema, json.dumps(mensaje), qos=1).wait_for_publish()
        print(tema, json.dumps(mensaje))
        if i < a.veces - 1:
            time.sleep(a.intervalo)
    cliente.loop_stop()
    cliente.disconnect()


if __name__ == "__main__":
    main()
