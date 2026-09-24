#!/bin/bash
# User-data para la SEGUNDA, TERCERA, CUARTA... EC2 (o ASG).
# Solo se conecta a RDS y monta el EFS ya inicializado por la EC2 1.
# NO ejecuta -i base ni crea/reinicializa la base de datos.
set -euo pipefail

# ====== CAMBIAR EN AMBOS USER-DATA: LOS MISMOS VALORES ======
DB_HOST="TU-ENDPOINT-RDS.rds.amazonaws.com"
DB_PORT="5432"
DB_NAME="odoo"
DB_USER="odoo"
DB_PASSWORD="CAMBIAR_PASSWORD_RDS"
EFS_DNS="fs-XXXXXXXX.efs.eu-west-1.amazonaws.com"
ODOO_VERSION="19.0"
# ==========================================================
EFS_MOUNT="/mnt/odoo-efs"

log() { echo "[odoo-replica] $*"; }
fail() { echo "[odoo-replica] ERROR: $*" >&2; exit 1; }

log "Instalando Docker y NFS"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io nfs-common
mkdir -p "$EFS_MOUNT" /opt/odoo/addons

log "Montando EFS compartido"
mount -t nfs4 -o nfsvers=4.1,hard,timeo=600,retrans=2,noresvport \
  "${EFS_DNS}:/" "$EFS_MOUNT"
mountpoint -q "$EFS_MOUNT" || fail "EFS no se ha montado"
printf '%s\n' "${EFS_DNS}:/ ${EFS_MOUNT} nfs4 nfsvers=4.1,hard,timeo=600,retrans=2,noresvport,_netdev 0 0" >> /etc/fstab

# Asegurar que Docker no arranque antes que EFS tras reiniciar la EC2.
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/odoo-efs.conf <<EOF
[Unit]
RequiresMountsFor=${EFS_MOUNT}
EOF
systemctl daemon-reload
systemctl enable --now docker

# Esperar hasta 10 min si la primera EC2 todavia esta inicializando.
log "Esperando a que la primera EC2 termine la inicializacion"
READY=0
for intento in $(seq 1 120); do
  if [[ -f "$EFS_MOUNT/.odoo-init-ready" && -d "$EFS_MOUNT/filestore/$DB_NAME" ]]; then
    READY=1
    break
  fi
  sleep 5
done
[[ "$READY" == "1" ]] || fail "No hay instalacion preparada en EFS; iniciar primero la EC2 1 o migrar el filestore existente"

log "Descargando y arrancando Odoo SIN inicializar la BD"
docker pull "odoo:${ODOO_VERSION}"
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
