#!/usr/bin/env bash
# Runs inside the build container as root. Installs MariaDB and loads the dump from stdin, if any.
set -euo pipefail

# Keep the dump on fd 3 so apt and systemctl can't read it.
exec 3<&0 </dev/null

DB="${ORB_BUILD_DB_NAME:-app}"

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mariadb-server >/dev/null
cat > /etc/mysql/mariadb.conf.d/zz-orb.cnf <<CNF
[mysqld]
bind-address = 127.0.0.1
innodb_buffer_pool_size = 256M
innodb_flush_log_at_trx_commit = 2
performance_schema = OFF
skip-log-bin
CNF
systemctl enable mariadb >/dev/null 2>&1
systemctl restart mariadb
mariadb -e "create database if not exists \`$DB\` character set utf8mb4;
  create user if not exists '$DB'@localhost identified by '$DB';
  grant all on \`$DB\`.* to '$DB'@localhost;"

mariadb "$DB" <&3

cat > /home/user/.my.cnf <<CNF
[client]
user=$DB
password=$DB
database=$DB
host=127.0.0.1
CNF
chown user:user /home/user/.my.cnf
chmod 600 /home/user/.my.cnf
