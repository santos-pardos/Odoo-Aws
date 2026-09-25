#!/bin/bash
set -e

dnf update -y
dnf install -y docker

systemctl enable --now docker
usermod -aG docker ec2-user

mkdir -p /usr/local/lib/docker/cli-plugins/
curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

mkdir -p /opt/odoo/odoo-data/.local
mkdir -p /opt/odoo/postgres-data
mkdir -p /opt/odoo/nginx
mkdir -p /home/ec2-user/odoo-pilot

chown -R 101:101 /opt/odoo/odoo-data
chmod -R 775 /opt/odoo/odoo-data

cd /home/ec2-user/odoo-pilot

cat <<EOF > odoo.conf
[options]
admin_passwd = admin_master_pilot
db_host = postgres
db_user = odoo
db_password = A123456b
db_port = 5432
http_port = 8069
proxy_mode = True
without_demo = all
EOF

cat <<EOF > /opt/odoo/nginx/default.conf
server {
    listen 80;
    server_name _;

    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;

    client_max_body_size 100m;

    location / {
        proxy_pass http://odoo:8069;
    }

    location /longpolling {
        proxy_pass http://odoo:8072;
    }

    location /websocket {
        proxy_pass http://odoo:8072;
    }
}
EOF

cat <<EOF > docker-compose.yml
services:
  postgres:
    image: postgres:15
    container_name: postgres_odoo
    environment:
      POSTGRES_DB: odoo
      POSTGRES_USER: odoo
      POSTGRES_PASSWORD: A123456b
    volumes:
      - /opt/odoo/postgres-data:/var/lib/postgresql/data
    restart: always
    networks:
      - odoo-net

  odoo:
    image: odoo:19
    container_name: odoo_piloto
    depends_on:
      - postgres
    volumes:
      - /opt/odoo/odoo-data:/var/lib/odoo
      - ./odoo.conf:/etc/odoo/odoo.conf:ro
    command: odoo -c /etc/odoo/odoo.conf -d odoo -i base --without-demo=all
    restart: always
    networks:
      - odoo-net

  nginx:
    image: nginx:latest
    container_name: nginx_odoo
    depends_on:
      - odoo
    ports:
      - "80:80"
    volumes:
      - /opt/odoo/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
    restart: always
    networks:
      - odoo-net

networks:
  odoo-net:
    driver: bridge
EOF

chown -R ec2-user:ec2-user /home/ec2-user/odoo-pilot

docker compose up -d
