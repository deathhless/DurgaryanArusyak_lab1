#!/bin/sh
LK=http://lakekeeper:8181

echo "[lk-init] bootstrap"
curl -s -o /dev/null -w "%{http_code}\n" -X POST "$LK/management/v1/bootstrap" \
  -H "Content-Type: application/json" -d '{"accept-terms-of-use": true}'

echo "[lk-init] создание warehouse"
code=$(curl -s -o /tmp/resp -w "%{http_code}" -X POST "$LK/management/v1/warehouse" \
  -H "Content-Type: application/json" -d @/create-warehouse.json)
cat /tmp/resp; echo

if [ "$code" = "200" ] || [ "$code" = "201" ]; then
  echo "[lk-init] warehouse создан"
elif grep -q "Overlap\|AlreadyExists" /tmp/resp; then
  echo "[lk-init] warehouse уже существует, пропускаем"
else
  echo "[lk-init] ошибка $code"; exit 1
fi