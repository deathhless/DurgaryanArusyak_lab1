#!/bin/sh
set -e

echo "[init] миграции БД Superset"
superset db upgrade

echo "[init] учётная запись admin"
superset fab create-admin \
  --username admin --firstname Admin --lastname User \
  --email admin@example.com --password admin || echo "[init] admin уже существует"

superset init

echo "[init] источник данных Trino -> Iceberg (каталог lakehouse)"
superset set-database-uri \
  -d "Trino Lakehouse" \
  -u "trino://admin@trino:8080/lakehouse"

echo "[init] загрузка дашбордов из /exports"
found=0
for f in /exports/*.zip; do
  [ -e "$f" ] || continue
  found=1
  echo "[init] import $f"
  superset import-dashboards -p "$f" -u admin
done
[ "$found" = 1 ] || echo "[init] в /exports нет .zip — дашборд не загружен (экспортируй его из UI)"

echo "[init] готово"
