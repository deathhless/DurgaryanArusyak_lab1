# Отчет по практической работе №1
## 1. Вариант и масштаб
| Поле | Значение |
|---|---|
| ФИО (как в VK Education) | Дургарян Арусяк |
| Вариант (запрос) | 3 - Q18 |
| Масштаб | `sf1` |

Выбор масштаба как  `sf1` связано с тем, что В lineitem около 6 млн строк: этого хватает, чтобы увидеть работу подзапроса с `HAVING` и разницу между кодеками сжатия, а весь стек спокойно работает на компе с Docker. Больший масштаб потребовал бы больше памяти Trino без новых выводов. Один и тот же `sf1` используется на всех слоях. Я могла поставить больше, так как оп позволяет, но решила не рисковать, так как этого тоже достаточно

## 2. Поднятые сервисы - и почему именно они

Как источник данных я использовала базу superset-database, из которой SQL-запросы через компонент superset поступают в trino. Trino обрабатывает запросы и маршрутизирует потоки данных. Далее основные данные направляются в объектное хранилище minio-silo S3, где хранятся в формате parquet. А служебные метаданные передаются в lakekeeper Iceberg REST Catalog, который, сохраняет их в базе данных postgres. А все это в свою очередь передаются в хранилище (minio s3 и postgres)

| Сервис | Роль | Почему именно он |
|---|---|---|
| `silo` | S3-совместимое хранилище, куда физически падают parquet-файлы | К MinIO нет доступа,поэтому silo, еще полный S3 API, поэтому Trino и Lakekeeper работают без доработок; облачный S3 не нужен |
| `postgres` | БД, где Lakekeeper хранит метаданные каталога | удобная для работы с бд |
| `lakekeeper` | Iceberg REST Catalog | Реализует стандартный REST-протокол Iceberg, поэтому каталог не привязан к движку |
| `trino` | SQL-движок | подключается к источникам через коннекторы, быстро делает джойны и агрегации, а для Iceberg поддерживает изменение таблиц
| `superset` + `superset-database` | BI поверх Lakehouse | графики и дашборды |

### Как поднимала стек
Все сервисы описаны в одном docker-compose.yml и поднимаются одной командой из папки проекта:
```Bash
docker compose up -d --build
```
Флаг -d запускает контейнеры в фоне, а --build собирает образ Superset из ./superset (в него добавлены драйверы Postgres и Trino). 
Потом состояние я проверяла командой:
```Bash
docker compose ps
```
Порядок запуска я задала через depends_on с условиями service_healthy и service_completed_successfully, поэтому каждый сервис стартует только после готовности того, от чего он зависит: minio-silo запускается первым. Когда его healthcheck проходит, minio-silo-init создаёт бакет warehouse и завершается.Параллельно запускается postgres. После lakekeeper-migrate создаёт таблицы каталога в Postgres и завершается. После успешной миграции стартует lakekeeper и после его healthy, запускается lakekeeper-init, который делает bootstrap и создаёт warehouse lakehouse из create-warehouse.json, указывающий на бакет warehouse в MinIO. trino ждёт сразу четыре условия: lakekeeper healthy, lakekeeper-init завершён, minio-silo healthy, minio-silo-init завершён. Так Trino не стартует, пока каталог и бакет не готовы. Параллельно поднимается superset-database. Когда она и Trino healthy, запускается superset-init: миграции, создание учётной записи, подключение к Trino и загрузка дашборда из superset/exports. И наконец-то после всего этого стартует superset

### `docker-compose.yml`
1. minio-silo
```yaml
  minio-silo: #объектное хранилище для данных
    image: pgsty/silo:latest #образ          
    container_name: minio-silo

    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin

    ports: ["9000:9000", "9001:9001"]
    command: server /data --console-address ":9001" #запуск сервера и консоли

    volumes:
      - minio-data:/data #пост хранение

    healthcheck: #проверка сервиса           
      test: ["CMD-SHELL", "curl -sf http://localhost:9000/minio/health/live || mc ready local"]
      interval: 5s
      timeout: 5s
      retries: 10
```
Это объектное хранилище. Порты 9000 (S3 API) и 9001 (веб-консоль), данные в томе `minio-data`. Healthcheck нужен, чтобы зависимые сервисы ждали готовности хранилища

2. minio-silo-init
```yaml
  minio-silo-init: #для создани бакета warehouse
    image: pgsty/mc:latest
    container_name: minio-silo-init
    depends_on:
      minio-silo:
        condition: service_healthy
    entrypoint: /bin/sh
    command: -c "mc alias set m http://minio-silo:9000 minioadmin minioadmin &&
      mc mb -p m/warehouse" #алиас и бакет
```
Одноразовый контейнер, который создаёт алиас `mc` и бакет `warehouse`, затем завершается

3. postgres
```yaml
  postgres: #бдшка
    image: postgres:16
    container_name: postgres
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    ports: ["5432:5432"]
    volumes:
      - pg-data:/var/lib/postgresql/data #пост хранение
    healthcheck: #проверочка
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 3s
      retries: 20
```
БД для Lakekeeper, том `pg-data`; готовность проверяется `pg_isready`

4. lakekeeper-migrate
```yaml
  lakekeeper-migrate: #таблицы каталога в бдшке 
    image: quay.io/lakekeeper/catalog:latest-main
    container_name: lakekeeper-migrate
    depends_on:
      postgres:
        condition: service_healthy
    command: migrate
    environment:
      LAKEKEEPER__PG_DATABASE_URL_READ: postgresql://postgres:postgres@postgres:5432/postgres #чтение из БД
      LAKEKEEPER__PG_DATABASE_URL_WRITE: postgresql://postgres:postgres@postgres:5432/postgres #запись в БД
      LAKEKEEPER__PG_ENCRYPTION_KEY: NOT-SECURE-KEY #ключ шифрования
```
Создаёт таблицы каталога в Postgres


5. lakekeeper
```yaml
   lakekeeper: #каталог
    image: quay.io/lakekeeper/catalog:latest-main
    container_name: lakekeeper
    depends_on:
      lakekeeper-migrate:
        condition: service_completed_successfully
      postgres:
        condition: service_healthy
    command: serve
    environment:
      LAKEKEEPER__PG_DATABASE_URL_READ: postgresql://postgres:postgres@postgres:5432/postgres
      LAKEKEEPER__PG_DATABASE_URL_WRITE: postgresql://postgres:postgres@postgres:5432/postgres
      LAKEKEEPER__PG_ENCRYPTION_KEY: NOT-SECURE-KEY
    ports: ["8181:8181"]
    healthcheck:                    
      test: ["CMD", "/home/nonroot/lakekeeper", "healthcheck"]
      interval: 5s
      timeout: 5s
      retries: 10
```
Iceberg REST Catalog: хранит метаданные таблиц (схемы, снапшоты, расположение файлов) в Postgres. Trino обращается к нему по порту 8181, а сами данные лежат в MinIO. Стартует только после успешной миграции и готовности БД; healthcheck нужен, чтобы lakekeeper-init и trino ждали его готовности

6. lakekeeper-init
```yaml
  lakekeeper-init: #для создания warehouse в каталоге
    image: curlimages/curl:latest
    container_name: lakekeeper-init
    depends_on:
      lakekeeper:
        condition: service_healthy
    volumes:
      - ./create-warehouse.json:/create-warehouse.json:ro
      - ./scripts/lakekeeper-init.sh:/lakekeeper-init.sh:ro
    entrypoint: ["/bin/sh", "/lakekeeper-init.sh"]

```
Одноразовый `curl`: bootstrap Lakekeeper и создание warehouse `lakehouse` из `create-warehouse.json` (бакет `warehouse`, S3-endpoint `minio-silo`)

7. trino
```yaml
  trino: #пишем тут SQL
    image: trinodb/trino:latest
    container_name: trino
    ports: ["8080:8080"]
    volumes:
      - ./trino/catalog:/etc/trino/catalog
    depends_on:
      lakekeeper:
        condition: service_healthy
      lakekeeper-init:
        condition: service_completed_successfully
      minio-silo:
        condition: service_healthy
      minio-silo-init:
        condition: service_completed_successfully
      healthcheck:
        test: ["CMD-SHELL", "trino --execute 'SELECT 1' > /dev/null 2>&1"]
        interval: 10s
        timeout: 10s
        retries: 20
        start_period: 20s
```
 SQL-движок, каталоги из `trino/catalog` 


8. superset-database
```yaml
  superset-database: #бдшка для superset
    image: postgres:17
    container_name: superset-database
    environment:
      POSTGRES_DB: superset
      POSTGRES_USER: superset
      POSTGRES_PASSWORD: superset
    volumes:
      - superset-db-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U superset -d superset"]
      interval: 5s
      timeout: 5s
      retries: 5
```
Отдельная Postgres для Superset: хранит источники данных, датасеты, графики и дашборды.

9. superset-init
```yaml
  superset-init: #инициализация superset
    build:
      context: ./superset
    container_name: superset-init
    depends_on:
      superset-database:
        condition: service_healthy
      trino:
        condition: service_healthy
    environment:
      SUPERSET_CONFIG_PATH: /app/pythonpath/superset_config.py
      SQLALCHEMY_DATABASE_URI: postgresql+psycopg2://superset:superset@superset-database:5432/superset
    volumes:
      - ./superset/superset_config.py:/app/pythonpath/superset_config.py:ro #конфиг (только чтение)
      - ./superset/exports:/exports:ro #готовые дашборды
      - ./scripts/superset-init.sh:/superset-init.sh:ro # скрипт инициализации
    entrypoint: ["/bin/sh", "/superset-init.sh"]
```
собирается из `./superset`; применяет миграции, создаёт учётную запись, регистрирует подключение к Trino и загружает дашборд из `superset/exports` 

10. superset 
```yaml
  superset: #веб-интерфейс
    build:
      context: ./superset              
    container_name: superset
    depends_on:
      superset-init:
        condition: service_completed_successfully
    environment:
      SUPERSET_CONFIG_PATH: /app/pythonpath/superset_config.py
      SQLALCHEMY_DATABASE_URI: postgresql+psycopg2://superset:superset@superset-database:5432/superset
    volumes:
      - ./superset/superset_config.py:/app/pythonpath/superset_config.py:ro
    ports:
      - "8088:8088"
    entrypoint: /bin/sh
    command: -c "/usr/bin/run-server.sh"
```
аеб-интерфейс на порту 8088; стартует после успешного `superset-init`

11. Тома
```yaml
volumes:
  minio-data:
  pg-data:
  superset-db-data:
```
для сохранения данных между перезапусками контейнеров: minio-data (хранилище), pg-data (метаданные каталога), superset-db-data (БД Superset)»



## 3. Разбор запроса - какие данные нужны

Запрос Q18 (клиенты по заказам с суммарным количеством товара больше 300):

| Таблица TPC-H | Нужные колонки | Что запрос с ними делает |
|---|---|---|
| `lineitem` | `orderkey`, `quantity` | подзапрос `GROUP BY orderkey HAVING sum(quantity) > 300`; `sum(quantity)` в выводе |
| `orders` | `orderkey`, `custkey`, `orderdate`, `totalprice` | фильтр `orderkey IN (...)`, join с клиентами и позициями, вывод и сортировка |
| `customer` | `custkey`, `name` | join по `custkey`, вывод имени |

Остальные колонки в хранилище не попадают

## 4. Медальон - решения по каждому слою
Здесь данные проходят три слоя, и каждый решает свою задачу: Bronze хранит исходные данные как есть, Silver хранит подготовленные (отфильтрованные и объединённые), а Gold хранит готовый результат для отчёта. Так видно, откуда взялся каждый показатель, любой слой можно пересобрать из предыдущего, а BI работает только с Gold и не нагружает сырые таблицы
Все команды я выполняла в SQL-консоли Trino. Она запускается внутри контейнера trino командой docker exec -it trino trino в терминале. Исходные данные берутся из каталога tpch в самом Trino: коннектор генерирует таблицы TPC-H на лету, ничего скачивать не нужно, а при одном масштабе (sf1) данные у всех одинаковые.
Новые таблицы создаются в каталоге lakehouse (формат Iceberg). Физически parquet-файлы лежат в хранилище minio-silo, в бакете warehouse, а метаданные таблиц (схема, снапшоты, расположение файлов) хранит lakekeeper в своей Postgres
Каждая таблица создана командой CREATE TABLE … AS SELECT (CTAS): Trino выполняет запрос и сразу записывает результат в новую таблицу. Параметры в WITH (format='PARQUET', compression_codec='ZSTD') задают формат файлов и кодек сжатия. После каждой команды Trino выводит CREATE TABLE: N rows, откуда я взяла число строк. Вес таблиц измерен запросом к служебной таблице Iceberg "<таблица>$files", где хранится размер каждого файла данных: SELECT sum(file_size_in_bytes)/1048576.0 FROM lakehouse.<схема>."<таблица>$files"

## Общие решения для всех слоёв: формат Parquet, сжатие ZSTD, без партиционирования

**Parquet** хранит данные по колонкам, поэтому запрос читает только нужные колонки, а не всю строку целиком
**ZSTD** выбран по результатам теста (раздел «Тесты производительности»): самый маленький файл при скорости, близкой к Snappy
**Партиционирование** не применялось: запрос Q18 ничего не фильтрует по ключу, который можно было бы сделать партицией (даты, например, участвуют только в выводе). На объёме sf1 партиции лишь создали бы множество мелких файлов, и чтение стало бы медленнее

### Bronze (сырой)

| Таблица | Колонки (что оставил) | Строк | Вес, МБ | Формат | Сжатие | Партиционирование | Обоснование |
|---|---|---|---|---|---|---|---|
| `bronze.customer` | custkey, name | 150 000 | 0,246 | Parquet | ZSTD | нет | Оставила только ключ для джойна и имя для вывода. Parquet хранит данные по колонкам, ZSTD по тесту даёт самый маленький файл. Таблица небольшая, поэтому разбивать её на партиции нет смысла|
| `bronze.orders` | orderkey, custkey, orderdate, totalprice | 1 500 000 | 12,889 | Parquet | ZSTD | нет | Оставила ключи для связи и поля, которые выводятся и сортируются в Q18. Фильтра по дате в запросе нет, поэтому партиционирование по `orderdate` не отсекло бы данные, а только создало бы много мелких файлов |
| `bronze.lineitem` | orderkey, quantity | 6 001 215 | 6,716 | Parquet | ZSTD | нет | Самая большая таблица, но запросу нужны только две колонки из 16. Колоночный формат и отбор колонок уменьшили её до 6,7 МБ: `quantity` (числа от 1 до 50) очень хорошо сжимается. Партиции не нужны: нет фильтра по ключу |

### Silver (очищенный)

| Таблица | Колонки (что оставил) | Строк | Вес, МБ | Формат | Сжатие | Партиционирование | Обоснование |
|---|---|---|---|---|---|---|---|
| `silver.big_orders` | orderkey, total_quantity | 57 | 0,0008 | Parquet | ZSTD | нет | Результат подзапроса Q18 (`HAVING sum(quantity) > 300`). Тяжёлая агрегация по 6 млн строк выполняется один раз, дальше работаем с 57 заказами. Для такого объёма партиции не нужны, оставлен тот же ZSTD, что и на других слоях|
| `silver.big_order_customers` | name, custkey, orderkey, orderdate, totalprice, total_quantity | 57 | 0,0023 | Parquet | ZSTD | нет | Объединение крупных заказов с заказами и клиентами. Джойн идёт по 57 строкам, а не по 1,5 млн, поэтому выполнился примерно за секунду. Отдельная таблица позволяет проверить объединение независимо от отбора заказов |

### Gold (витрина)

| Таблица | Колонки | Строк | Вес, МБ | Формат | Сжатие | Партиционирование | Обоснование |
|---|---|---|---|---|---|---|---|
| `gold.q18_large_volume_customer` | name, custkey, orderkey, orderdate, totalprice, total_quantity | 57 | 0,0023 | Parquet | ZSTD | нет | Готовый ответ на Q18: сортировка по сумме заказа по убыванию, затем по дате, `LIMIT 100`. Строк 57, а не 100, потому что в `sf1` подходящих заказов всего 57. Формат тот же, что и на других слоях, чтобы BI-инструмент читал её без дополнительной настройки. Результат совпал с эталонным запросом (проверка `EXCEPT` дала 0 строк) |


## Схемы (слои)
Сначала я создала три схемы в каталоге lakehouse по одной на слой:

```sql
CREATE SCHEMA lakehouse.bronze;
CREATE SCHEMA lakehouse.silver;
CREATE SCHEMA lakehouse.gold;
```
## Bronze
Взяла из tpch.sf1 в lakehouse.bronze три таблицы, которые нужны запросу Q18: customer, orders, lineitem.
```sql
CREATE TABLE lakehouse.bronze.customer WITH (format='PARQUET', compression_codec='ZSTD') AS
SELECT custkey, name FROM tpch.sf1.customer;

CREATE TABLE lakehouse.bronze.orders WITH (format='PARQUET', compression_codec='ZSTD') AS
SELECT orderkey, custkey, orderdate, totalprice FROM tpch.sf1.orders;

CREATE TABLE lakehouse.bronze.lineitem WITH (format='PARQUET', compression_codec='ZSTD') AS
SELECT orderkey, quantity FROM tpch.sf1.lineitem;
```
Trino вернул CREATE TABLE: 150000 rows, 1500000 rows и 6001215 rows. Количество строк совпало с исходными таблицами: данные при копировании не теряются и не фильтруются
Оставила только нужные колонки, так как остальные запросу не нужны, а хранить и читать их значит тратить место и время. Значения строк при этом не менялись, фильтров на этом слое нет

## Silver
Из Bronze я построила две таблицы: сначала отобрала «крупные» заказы, затем присоединила к ним клиентов
```sql
CREATE TABLE lakehouse.silver.big_orders WITH (format='PARQUET', compression_codec='ZSTD') AS
SELECT orderkey, sum(quantity) AS total_quantity
FROM lakehouse.bronze.lineitem
GROUP BY orderkey HAVING sum(quantity) > 300;

CREATE TABLE lakehouse.silver.big_order_customers WITH (format='PARQUET', compression_codec='ZSTD') AS
SELECT c.name, c.custkey, o.orderkey, o.orderdate, o.totalprice, b.total_quantity
FROM lakehouse.silver.big_orders b
JOIN lakehouse.bronze.orders   o ON o.orderkey = b.orderkey
JOIN lakehouse.bronze.customer c ON c.custkey  = o.custkey;
```
В обеих таблицах теперь по 57 строк: во всём наборе sf1 только 57 заказов, где суммарное количество больше 300
Самая тяжёлая часть Q18 это как раз группировка 6 млн строк lineitem. Я выполняю её один раз и сохраняю результат в big_orders (57 строк), поэтому дальше запросы не перечитывают шесть миллионов строк. Join идёт уже по 57 заказам, а не по всем 1,5 млн, поэтому выполняется за секунду (в логе - 1,1 с) и читает мало данных.Две таблицы вместо одной нужны, чтобы шаги были видны отдельно: можно проверить отбор крупных заказов независимо от объединения с клиентами. Суммарные размеры слоя крошечные (доли килобайта), то есть после отбора данные сократились в 100 000 раз


## Gold
```sql
CREATE TABLE lakehouse.gold.q18_large_volume_customer WITH (format='PARQUET', compression_codec='ZSTD') AS
SELECT name, custkey, orderkey, orderdate, totalprice, total_quantity
FROM lakehouse.silver.big_order_customers
ORDER BY totalprice DESC, orderdate
LIMIT 100;
```
В таблице 57 строк (не 100, потому что подходящих заказов всего 57, и LIMIT 100 ничего не отрезал). Первая строка у меня самый крупный заказ: Customer#000128120, заказ 4722021, сумма 544089.09, количество 323

## Проверка корректности
Здесь я проверила совпадает ли голд ч эталонным запросом, который в 6tpch.sf1 выполняеся
```sql
SELECT count(*) FROM (
  SELECT * FROM lakehouse.gold.q18_large_volume_customer
  EXCEPT
  SELECT c.name, c.custkey, o.orderkey, o.orderdate, o.totalprice, sum(l.quantity)
  FROM tpch.sf1.customer c
  JOIN tpch.sf1.orders o ON c.custkey = o.custkey
  JOIN tpch.sf1.lineitem l ON o.orderkey = l.orderkey
  WHERE o.orderkey IN (SELECT orderkey FROM tpch.sf1.lineitem GROUP BY orderkey HAVING sum(quantity) > 300)
  GROUP BY c.name, c.custkey, o.orderkey, o.orderdate, o.totalprice
);
```
В итоге получила 0,как и надо ыбло. Значит, цепочка Bronze, Silver, Gold даёт тот же результат, что и исходный запрос. Эта проверка выполнялась 15 секунд, потому что эталонный запрос читает все 13,8 млн строк исходных таблиц, тогда как Gold отвечает за доли секунды


## 5. Тесты производительности
Bronze пересоздан с разными кодеками; запрос Q18 выполнялся 3 раза, берётся медиана:
```sql
CREATE TABLE lakehouse.bronze.lineitem_gzip   WITH (format='PARQUET', compression_codec='GZIP')   AS SELECT orderkey, quantity FROM tpch.sf1.lineitem;
CREATE TABLE lakehouse.bronze.lineitem_snappy WITH (format='PARQUET', compression_codec='SNAPPY') AS SELECT orderkey, quantity FROM tpch.sf1.lineitem;
CREATE TABLE lakehouse.bronze.lineitem_zstd   WITH (format='PARQUET', compression_codec='ZSTD')   AS SELECT orderkey, quantity FROM tpch.sf1.lineitem;

SELECT count(*) FROM (SELECT orderkey FROM lakehouse.bronze.lineitem_<кодек> GROUP BY orderkey HAVING sum(quantity) > 300);
```
Время запроса взято из system.runtime.queries (date_diff('millisecond', started, "end")). На всех таблицах результат одинаковый: 57 заказов

| Сжатие | Время запроса | Размер Bronze, МБ | Вывод |
|---|---|---|---|
| GZIP | 2,64 c | 7,56 | Самый медленный и в чтении, и в записи; размер хуже, чем у ZSTD |
| Snappy | 0,96 c | 13,76 | Самый быстрый, но файл вдвое больше |
| ZSTD | 1,23 c | 6,72 | Самый маленький файл, скорость почти как у Snappy |

ZSTD лучший по соотношению размер/скорость: он сжимает почти вдвое сильнее Snappy (6,7 против 13,8 МБ) и работает заметно быстрее GZIP (1,23 против 2,64 с), при этом файл даже меньше, чем у GZIP (6,7 против 7,6 МБ). Snappy быстрее ZSTD примерно на 0,3 с, но ценой удвоения объёма на диске. GZIP проигрывает по обоим показателям. Поэтому для всех слоёв выбран ZSTD

## 6. Часть 2 — осмысление и работа с инструментами
### 6.1. Понять и объяснить

| Вопрос | Твой ответ  |
|---|---|
| Зачем нужны большие данные и lakehouse (а не обычная БД/хранилище)? |Обычная БД (OLTP) оптимизирована под много коротких транзакций над строками; аналитика (OLAP) читает огромные объёмы по нескольким колонкам, и тут нужны колоночное хранение и масштабирование. Хранилище данных (DWH) дорого и привязывает данные к одному движку; «озеро» дёшево, но без транзакций и схемы. Lakehouse объединяет оба подхода: данные лежат в объектном хранилище в открытом формате (parquet), хранение отделено от вычислений (любой движок читает те же таблицы), а Iceberg добавляет ACID, схему, снапшоты и time travel|
| Пример schema evolution на Silver: добавил/переименовал колонку — что произошло? | В таблице silver.big_order_customers я добавила колонку segment (ALTER TABLE … ADD COLUMN) и переименовала name в customer_name (RENAME COLUMN). Файлы с данными при этом не переписывались: Iceberg изменил только метаданные. Старые строки читаются без ошибок, у новой колонки в них значение NULL, а переименованная колонка отдаёт те же данные под новым именем. Это работает потому, что Iceberg отслеживает колонки по внутреннему id, а не по имени. В обычной БД такая операция на большой таблице могла бы блокировать её или переписывать все данные. Скрипт и вывод ниже |
| Пример скрипта восстановления данных из снапшота (time travel) | Каждое изменение таблицы Iceberg создаёт снапшот. Я посмотрела список снапшотов silver.big_orders, удалила часть строк командой DELETE («авария») и вернула таблицу в состояние до удаления процедурой rollback_to_snapshot. Скрипт ниже. После отката количество строк снова стало равно 57 |


### Пример Schema evolution на Silver-слое

Я добавила колонку segment и переименовала name в customer_name в таблице silver.big_order_customers. После этого таблица продолжает читаться: старые строки на месте, имена клиентов остались под новым названием колонки, а в новой колонке segment у всех строк NULL. Файлы с данными при этом не переписывались — Iceberg изменил только метаданные
```sql
ALTER TABLE lakehouse.silver.big_order_customers ADD COLUMN segment varchar;
ALTER TABLE lakehouse.silver.big_order_customers RENAME COLUMN name TO customer_name;
SELECT * FROM lakehouse.silver.big_order_customers LIMIT 3;
```
![схема](images/schema-evolution.png)



### Разрушительные изменения и восстановление данных из снапшота
Я посмотрела список снапшотов silver.big_orders, удалила часть строк командой DELETE («авария») и вернула таблицу в состояние до удаления процедурой rollback_to_snapshot
```sql
SELECT snapshot_id, committed_at, operation FROM lakehouse.silver."big_orders$snapshots" ORDER BY committed_at;
DELETE FROM lakehouse.silver.big_orders WHERE total_quantity < 320; //опа авария
CALL lakehouse.system.rollback_to_snapshot('silver', 'big_orders', <snapshot_id до DELETE>);
SELECT count(*) FROM lakehouse.silver.big_orders; // ура починили                     
```
![снэпшот](images/snapshots.png)
![роллбэк](images/rollback.png)



### 6.2. Подключить инструмент к lakehouse
Я выбрала **Apache Superset**, потому что у него открытый код, ставится в Docker, подключается к Trino, а значит и к Iceberg-таблицам в MinIO без собственных коннекторов. Doris/StarRocks/Spark для одного запроса на `sf1` избыточны, Trino уже справляется.сервисы `superset-database`, `superset-init`, `superset` в `docker-compose.yml`. Подключение `trino://admin@trino:8080/lakehouse` создаётся скриптом `scripts/superset-init.sh`.

Для начала я вошла в интерфейс, который http://localhost:8088, ипользовала логи и пароль admin. После в настройках посмотрела подключения бд, там уже была подключена моя бдшка Trino Lakehouse
 ![бд](images/1.png)
После я зашла в SQL Lab и там я выбрала базу «Trino Lakehouse» и схему bronze. Слева отобразились таблицы слоя. Запрос SELECT count(*) FROM bronze.lineitem вернул 6 001 215 строк, то есть то же число, что показал Trino в консоли: Superset читает те же Iceberg-таблицы, которые лежат в хранилище. Запрос SELECT * FROM bronze.orders LIMIT 10 вывел первые строки таблицы заказов
![график 1](images/2.png)

Из SQL Lab я сохранила результаты запросов как датасеты (Save → Save dataset) и построила графики:
**Заказы по годам**, Pie Chart, по Bronze-таблице orders: запрос по оси X год, метрика SUM по orders.
```sql
SELECT year(orderdate) AS year, count(*) AS orders FROM lakehouse.bronze.orders GROUP BY 1 ORDER BY 1;
```
**Крупнейшие заказы Q18**, Bar Chart, по витрине Gold: 10 самых крупных заказов, по оси X имя клиента, метрика MAX по totalprice.
```sql
SELECT name, totalprice
FROM lakehouse.gold.q18_large_volume_customer
ORDER BY totalprice DESC
LIMIT 10;
```
**Число крупных заказов**, Big Number, по витрине Gold: итоговое значение 57, что совпадает с числом строк в gold.q18_large_volume_customer
```sql
SELECT count(*) AS big_orders
FROM lakehouse.gold.q18_large_volume_customer;
```
Графики собраны в дашборд. Он показывает слои медальона: график 1 строится по Bronze, графики 2 и 3 по Gold. Дашборд экспортирован в superset/exports/
![Дащборд](superset/exports/q-18.jpg)
## Выводы

Медальон, как я поняла, просто делит ответственность: Bronze хранит сырые данные без потерь, Silver хранит очищенную и объединённую модель (выделение крупных заказов и джойн), Gold хранит готовый ответ на запрос, что упрощает проверку и BI. Parquet с ZSTD подходит для всех слоёв: колоночное чтение берёт только нужные колонки, а сжатие экономит место при небольших затратах CPU. Партиционирование на `sf1` не применялось: запрос не фильтрует по ключу партиции, а данные малы. Iceberg поверх MinIO с Lakekeeper даёт schema evolution и time travel без переписывания данных, чего не даёт обычная БД

