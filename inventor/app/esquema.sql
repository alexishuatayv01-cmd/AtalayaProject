CREATE TABLE IF NOT EXISTS condominios (
  id SERIAL PRIMARY KEY,
  codigo TEXT NOT NULL UNIQUE,
  nombre TEXT NOT NULL,
  direccion TEXT,
  latitud DOUBLE PRECISION,
  longitud DOUBLE PRECISION,
  de_prueba BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS sistemas (
  id SERIAL PRIMARY KEY,
  condominio_id INT NOT NULL REFERENCES condominios(id),
  tipo TEXT NOT NULL,
  nombre TEXT NOT NULL,
  estado TEXT NOT NULL DEFAULT 'sin_datos',
  actualizado_en TIMESTAMPTZ,
  UNIQUE (condominio_id, nombre)
);

CREATE TABLE IF NOT EXISTS dispositivos (
  id SERIAL PRIMARY KEY,
  codigo TEXT NOT NULL UNIQUE,
  sistema_id INT NOT NULL REFERENCES sistemas(id),
  ultimo_contacto TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS eventos (
  id BIGSERIAL PRIMARY KEY,
  dispositivo_id INT NOT NULL REFERENCES dispositivos(id),
  id_mensaje TEXT NOT NULL,
  hora_dispositivo TIMESTAMPTZ NOT NULL,
  recibido_en TIMESTAMPTZ NOT NULL DEFAULT now(),
  datos JSONB NOT NULL,
  UNIQUE (dispositivo_id, id_mensaje)
);

-- Propuesta inicial: las horas se ajustan aquí, sin tocar el código.
CREATE TABLE IF NOT EXISTS categorias_sla (
  codigo TEXT PRIMARY KEY,
  nombre TEXT NOT NULL,
  horas_limite NUMERIC NOT NULL
);

CREATE TABLE IF NOT EXISTS alarmas (
  id BIGSERIAL PRIMARY KEY,
  dispositivo_id INT NOT NULL REFERENCES dispositivos(id),
  tipo TEXT NOT NULL,
  severidad TEXT NOT NULL,
  estado TEXT NOT NULL,
  desde TIMESTAMPTZ NOT NULL,
  activada_en TIMESTAMPTZ,
  cerrada_en TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS una_alarma_abierta
  ON alarmas (dispositivo_id, tipo) WHERE estado <> 'cerrada';

CREATE TABLE IF NOT EXISTS tickets (
  id BIGSERIAL PRIMARY KEY,
  condominio_id INT NOT NULL REFERENCES condominios(id),
  sistema_id INT REFERENCES sistemas(id),
  alarma_id BIGINT REFERENCES alarmas(id),
  categoria TEXT NOT NULL REFERENCES categorias_sla(codigo),
  titulo TEXT NOT NULL,
  estado TEXT NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente', 'no_resuelto', 'resuelto')),
  origen TEXT NOT NULL,
  creado_en TIMESTAMPTZ NOT NULL DEFAULT now(),
  limite TIMESTAMPTZ NOT NULL,
  resuelto_en TIMESTAMPTZ
);

CREATE OR REPLACE VIEW tickets_sla AS
  SELECT t.*, (t.estado <> 'resuelto' AND now() > t.limite) AS sla_rojo
  FROM tickets t;

INSERT INTO categorias_sla (codigo, nombre, horas_limite) VALUES
  ('critica', 'Crítica', 4),
  ('alta', 'Alta', 24),
  ('media', 'Media', 72),
  ('baja', 'Baja', 168)
ON CONFLICT (codigo) DO NOTHING;

-- Datos de ejemplo para las pruebas; no son un condominio real.
INSERT INTO condominios (codigo, nombre, de_prueba)
  VALUES ('prueba', 'Condominio de prueba', TRUE)
ON CONFLICT (codigo) DO NOTHING;
INSERT INTO sistemas (condominio_id, tipo, nombre)
  SELECT id, 'camaras', 'Cámara 2' FROM condominios WHERE codigo = 'prueba'
ON CONFLICT (condominio_id, nombre) DO NOTHING;
INSERT INTO dispositivos (codigo, sistema_id)
  SELECT 'esp32-cam-02', s.id FROM sistemas s WHERE s.nombre = 'Cámara 2'
ON CONFLICT (codigo) DO NOTHING;

-- Servidor local de cada condominio.
CREATE TABLE IF NOT EXISTS sitios (
  id SERIAL PRIMARY KEY,
  codigo TEXT NOT NULL UNIQUE,
  condominio_id INT NOT NULL UNIQUE REFERENCES condominios(id),
  clave_sha256 TEXT NOT NULL,
  activo BOOLEAN NOT NULL DEFAULT FALSE,
  ultimo_contacto TIMESTAMPTZ,
  conectado_desde TIMESTAMPTZ
);
ALTER TABLE alarmas ADD COLUMN IF NOT EXISTS sitio_id INT REFERENCES sitios(id);
ALTER TABLE alarmas ALTER COLUMN dispositivo_id DROP NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS una_alarma_sitio_abierta
  ON alarmas (sitio_id, tipo) WHERE estado <> 'cerrada' AND sitio_id IS NOT NULL;

INSERT INTO condominios (codigo, nombre, de_prueba)
  VALUES ('prueba-sitio', 'Condominio de prueba con servidor local', TRUE)
ON CONFLICT (codigo) DO NOTHING;
INSERT INTO sistemas (condominio_id, tipo, nombre)
  SELECT c.id, v.tipo, v.nombre FROM condominios c,
    (VALUES ('camaras', 'Cámara 1'), ('grupo_electrogeno', 'Grupo electrógeno')) AS v(tipo, nombre)
  WHERE c.codigo = 'prueba-sitio'
ON CONFLICT (condominio_id, nombre) DO NOTHING;
INSERT INTO dispositivos (codigo, sistema_id)
  SELECT v.codigo, s.id FROM sistemas s JOIN condominios c ON c.id = s.condominio_id,
    (VALUES ('esp32-sitio-01', 'Cámara 1'), ('esp32-sitio-02', 'Grupo electrógeno')) AS v(codigo, nombre)
  WHERE c.codigo = 'prueba-sitio' AND s.nombre = v.nombre
ON CONFLICT (codigo) DO NOTHING;
