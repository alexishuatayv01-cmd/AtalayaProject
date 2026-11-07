#!/bin/bash
# Copia la base de datos y las fotos al otro disco (NVMe). Conserva 14 días.
set -euo pipefail
cd /mnt/DATOS/servidor/inventor
DESTINO="$HOME/respaldos-inventor"
mkdir -p "$DESTINO/fotos"
ARCHIVO="$DESTINO/base-$(date +%F-%H%M%S).dump"
docker compose exec -T db sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$ARCHIVO.parcial"
mv "$ARCHIVO.parcial" "$ARCHIVO"
rsync -a datos/fotos/ "$DESTINO/fotos/"
find "$DESTINO" -maxdepth 1 -name 'base-*.dump' -mtime +14 -delete
echo "respaldo: $ARCHIVO"
