![alt text](Architecture.png)
## Create VPC Odoo
```
CIDR: 10.0.0.0/16
6 Subnets: 10.0.x.0/24
1 NAT GW
```
## Create 4 SG
```
SGec2: 22 y 80
SGalb: 80
SGefs: 2049
SGpostgres: 5432
```
## Create RDS Postgress (Get EndPoint)
```
User: odoo
Password A123456b
BBDD: odoo
```
