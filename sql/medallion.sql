CREATE SCHEMA IF NOT EXISTS lakehouse.bronze;
CREATE SCHEMA IF NOT EXISTS lakehouse.silver;
CREATE SCHEMA IF NOT EXISTS lakehouse.gold;

--BRONZE:сырые копии только нужных колонок
CREATE TABLE lakehouse.bronze.customer WITH (format='PARQUET', compression_codec='ZSTD') AS
  SELECT custkey, name FROM tpch.sf1.customer;
CREATE TABLE lakehouse.bronze.orders WITH (format='PARQUET', compression_codec='ZSTD') AS
  SELECT orderkey, custkey, orderdate, totalprice FROM tpch.sf1.orders;
CREATE TABLE lakehouse.bronze.lineitem WITH (format='PARQUET', compression_codec='ZSTD') AS
  SELECT orderkey, quantity FROM tpch.sf1.lineitem;
  
--SILVER: сначала крупные заказы (подзапрос Q18), затем join
CREATE TABLE lakehouse.silver.big_orders WITH (format='PARQUET', compression_codec='ZSTD') AS
  SELECT orderkey, sum(quantity) AS total_quantity
  FROM lakehouse.bronze.lineitem
  GROUP BY orderkey HAVING sum(quantity) > 300;

CREATE TABLE lakehouse.silver.big_order_customers WITH (format='PARQUET', compression_codec='ZSTD') AS
  SELECT c.name, c.custkey, o.orderkey, o.orderdate, o.totalprice, b.total_quantity
  FROM lakehouse.silver.big_orders b
  JOIN lakehouse.bronze.orders   o ON o.orderkey = b.orderkey
  JOIN lakehouse.bronze.customer c ON c.custkey  = o.custkey;

--GOLD: топ-100
CREATE TABLE lakehouse.gold.q18_large_volume_customer WITH (format='PARQUET', compression_codec='ZSTD') AS
  SELECT name, custkey, orderkey, orderdate, totalprice, total_quantity
  FROM lakehouse.silver.big_order_customers
  ORDER BY totalprice DESC, orderdate
  LIMIT 100;

--Проверка:Gold должен совпасть с эталонным Q18
SELECT count(*) FROM (
  (SELECT * FROM lakehouse.gold.q18_large_volume_customer
   EXCEPT
   SELECT c.name,c.custkey,o.orderkey,o.orderdate,o.totalprice,sum(l.quantity)
   FROM tpch.sf1.customer c JOIN tpch.sf1.orders o ON c.custkey=o.custkey
   JOIN tpch.sf1.lineitem l ON o.orderkey=l.orderkey
   WHERE o.orderkey IN (SELECT orderkey FROM tpch.sf1.lineitem GROUP BY orderkey HAVING sum(quantity)>300)
   GROUP BY 1,2,3,4,5)
);  --рез 0

--Метрики для отчёта
SELECT 'bronze.customer', count(*) FROM lakehouse.bronze.customer UNION ALL
SELECT 'bronze.orders',   count(*) FROM lakehouse.bronze.orders   UNION ALL
SELECT 'bronze.lineitem', count(*) FROM lakehouse.bronze.lineitem UNION ALL
SELECT 'silver.big_orders', count(*) FROM lakehouse.silver.big_orders UNION ALL
SELECT 'silver.big_order_customers', count(*) FROM lakehouse.silver.big_order_customers UNION ALL
SELECT 'gold.q18', count(*) FROM lakehouse.gold.q18_large_volume_customer;
--размер таблицы в МБ:
SELECT sum(file_size_in_bytes)/1048576.0 AS mb FROM lakehouse.bronze."lineitem$files";

--Тест сжатия (раздел «Тесты производительности»)
CREATE TABLE lakehouse.bronze.lineitem_gzip   WITH (format='PARQUET', compression_codec='GZIP')   AS SELECT orderkey, quantity FROM tpch.sf1.lineitem;
CREATE TABLE lakehouse.bronze.lineitem_snappy WITH (format='PARQUET', compression_codec='SNAPPY') AS SELECT orderkey, quantity FROM tpch.sf1.lineitem;
CREATE TABLE lakehouse.bronze.lineitem_zstd   WITH (format='PARQUET', compression_codec='ZSTD')   AS SELECT orderkey, quantity FROM tpch.sf1.lineitem;

SELECT sum(file_size_in_bytes)/1048576.0 AS mb FROM lakehouse.bronze."lineitem_gzip$files";
SELECT sum(file_size_in_bytes)/1048576.0 AS mb FROM lakehouse.bronze."lineitem_snappy$files";
SELECT sum(file_size_in_bytes)/1048576.0 AS mb FROM lakehouse.bronze."lineitem_zstd$files";

--на каждой копии (по 3 прогона)
SELECT count(*) FROM (SELECT orderkey FROM lakehouse.bronze.lineitem_gzip   GROUP BY orderkey HAVING sum(quantity) > 300);
SELECT count(*) FROM (SELECT orderkey FROM lakehouse.bronze.lineitem_snappy GROUP BY orderkey HAVING sum(quantity) > 300);
SELECT count(*) FROM (SELECT orderkey FROM lakehouse.bronze.lineitem_zstd   GROUP BY orderkey HAVING sum(quantity) > 300);

--время запросов в секундах
SELECT query_id, date_diff('millisecond', started, "end")/1000.0 AS sec, substr(query, 1, 80) AS q
FROM system.runtime.queries ORDER BY created DESC LIMIT 15;

--Schema evolution (6.1)
ALTER TABLE lakehouse.silver.big_order_customers ADD COLUMN segment varchar;
ALTER TABLE lakehouse.silver.big_order_customers RENAME COLUMN name TO customer_name;
SELECT * FROM lakehouse.silver.big_order_customers LIMIT 3;  --старые файлы читаются, новая колонка = NULL

--Time travel (6.1)
SELECT snapshot_id, committed_at, operation FROM lakehouse.silver."big_orders$snapshots" ORDER BY committed_at;
DELETE FROM lakehouse.silver.big_orders WHERE total_quantity < 320;  
--восстановление: подставить snapshot_id до DELETE
CALL lakehouse.system.rollback_to_snapshot('silver', 'big_orders', <SNAPSHOT_ID_ДО_DELETE>);