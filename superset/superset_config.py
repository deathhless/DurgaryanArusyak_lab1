import os

SECRET_KEY = os.environ.get("SUPERSET_SECRET_KEY", "change-me-to-a-long-random-string")
SQLALCHEMY_DATABASE_URI = os.environ["SQLALCHEMY_DATABASE_URI"]

#для учебного стенда
WTF_CSRF_ENABLED = True
TALISMAN_ENABLED = False
SUPERSET_WEBSERVER_TIMEOUT = 120
