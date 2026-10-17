FROM apache/superset:4.1.1
USER root
# драйвер Postgres (БД Superset) и Trino (источник данных)
RUN pip install --no-cache-dir psycopg2-binary trino sqlalchemy-trino
USER superset
