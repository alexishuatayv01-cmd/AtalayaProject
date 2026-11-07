import os
import time

import psycopg
from psycopg.rows import dict_row


def conectar(autocommit=True):
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
        dbname=os.environ["POSTGRES_DB"],
        autocommit=autocommit,
        row_factory=dict_row,
    )


def conectar_con_espera():
    while True:
        try:
            return conectar()
        except psycopg.OperationalError:
            time.sleep(2)
