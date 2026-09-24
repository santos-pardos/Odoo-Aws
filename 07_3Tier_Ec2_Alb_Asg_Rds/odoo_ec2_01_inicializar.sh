#!/bin/bash
# User-data de la PRIMERA EC2: SOLO para despliegue nuevo.
# Requiere: BD 'odoo' creada y VACIA en RDS y EFS nuevo/vacio.
# Si ya tienes Odoo funcionando con filestore local, NO uses este script
# para migrarlo: copia antes ese filestore a EFS y usa el segundo user-data.
set -euo pipefail

# ====== CAMBIAR EN AMBOS USER-DATA ======
DB_HOST="TU-ENDPOINT-RDS.rds.amazonaws.com"
DB_PORT="5432"
DB_NAME="odoo"
DB_USER="odoo"
DB_PASSWORD="CAMBIAR_PASSWORD_RDS"
EFS_DNS="fs-XXXXXXXX.efs.eu-west-1.amazonaws.com"
ODOO_VERSION="19.0"
# =======================================
EFS_MOUNT="/mnt/odoo-efs"

log() { echo "[odoo-init] $*"; }
fail() { echo "[odoo-init] ERROR: $*" >&2; exit 1; }

log "Instalando dependencias"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io nfs-common postgresql-client
mkdir -p "$EFS_MOUNT" /opt/odoo/addons

# Montar antes de arrancar Docker para no escribir datos por error en disco local.
log "Montando EFS"
mount -t nfs4 -o nfsvers=4.1,hard,timeo=600,retrans=2,noresvport \
  "${EFS_DNS}:/" "$EFS_MOUNT"
mountpoint -q "$EFS_MOUNT" || fail "EFS no se ha montado"
printf '%s\n' "${EFS_DNS}:/ ${EFS_MOUNT} nfs4 nfsvers=4.1,hard,timeo=600,retrans=2,noresvport,_netdev 0 0" >> /etc/fstab

# En reinicios, impedir que el demonio Docker arranque antes de EFS.
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/odoo-efs.conf <<EOF
[Unit]
RequiresMountsFor=${EFS_MOUNT}
EOF
systemctl daemon-reload
systemctl enable --now docker

# NO instalar de nuevo una BD que ya tenga datos; NO tocar filestore previo.
[[ ! -e "$EFS_MOUNT/.odoo-init-ready" ]] || fail "EFS ya contiene una instalacion marcada como lista; usa el user-data de replicas"
[[ ! -e "$EFS_MOUNT/filestore/$DB_NAME" ]] || fail "Ya existe el filestore de $DB_NAME en EFS: no inicializar"

log "Comprobando que la base de datos $DB_NAME existe y no esta inicializada"
# Si RDS no tiene creada la base 'odoo', este comando FALLA; crearla antes.
DB_STATUS="$(PGPASSWORD="$DB_PASSWORD" psql -X -v ON_ERROR_STOP=1 \
  -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -Atq \
  -c "SELECT CASE WHEN to_regclass('public.ir_module_module') IS NULL THEN 'vacia' ELSE 'iniciada' END")" \
  || fail "No se puede consultar RDS; comprueba la conexion y que exista la BD $DB_NAME"
[[ "$DB_STATUS" == "vacia" ]] || fail "La BD tiene tablas de Odoo o instalacion parcial; NO ejecutar -i base"

log "Descargando Odoo"
docker pull "odoo:${ODOO_VERSION}"
# UID/GID reales del usuario odoo dentro de la imagen oficial.
ODOO_UID="$(docker run --rm --entrypoint id "odoo:${ODOO_VERSION}" -u)"
ODOO_GID="$(docker run --rm --entrypoint id "odoo:${ODOO_VERSION}" -g)"
chown "${ODOO_UID}:${ODOO_GID}" "$EFS_MOUNT" /opt/odoo/addons
chmod 775 "$EFS_MOUNT" /opt/odoo/addons

log "Inicializando SOLO una vez la BD $DB_NAME"
docker run --rm \
  --name odoo19-init \
  -e HOST="$DB_HOST" -e PORT="$DB_PORT" \
  -e USER="$DB_USER" -e PASSWORD="$DB_PASSWORD" \
  --mount "type=bind,src=$EFS_MOUNT,dst=/var/lib/odoo" \
  --mount "type=bind,src=/opt/odoo/addons,dst=/mnt/extra-addons" \
  "odoo:${ODOO_VERSION}" \
  -d "$DB_NAME" -i base --without-demo=all --stop-after-init

log "Verificando la inicializacion"
BASE_STATUS="$(PGPASSWORD="$DB_PASSWORD" psql -X -v ON_ERROR_STOP=1 \
  -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -Atq \
  -c "SELECT state FROM ir_module_module WHERE name='base' LIMIT 1")"
[[ "$BASE_STATUS" == "installed" ]] || fail "El modulo base no esta instalado; consultar logs y no lanzar replicas"
mkdir -p "$EFS_MOUNT/filestore/$DB_NAME"
chown -R "${ODOO_UID}:${ODOO_GID}" "$EFS_MOUNT/filestore/$DB_NAME"
# Solo ahora las otras EC2 pueden arrancar.
touch "$EFS_MOUNT/.odoo-init-ready"

log "Arrancando Odoo de la primera EC2"
docker run -d \
  --name odoo19 --restart unless-stopped \
  -p 80:8069 -p 8072:8072 \
  -e HOST="$DB_HOST" -e PORT="$DB_PORT" \
  -e USER="$DB_USER" -e PASSWORD="$DB_PASSWORD" \
  --mount "type=bind,src=$EFS_MOUNT,dst=/var/lib/odoo" \
  --mount "type=bind,src=/opt/odoo/addons,dst=/mnt/extra-addons" \
  "odoo:${ODOO_VERSION}" \
  -d "$DB_NAME" --db-filter="^${DB_NAME}$" \
  --proxy-mode --workers=2 --gevent-port=8072
log "Finalizado; comprobar: docker ps && docker logs --tail=100 odoo19"
