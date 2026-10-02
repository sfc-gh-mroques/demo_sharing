"""Déploie la procédure OPTIMIZE_ROUTES (setup/optimizer_sproc.sql).

Le corps Python contient des '$$', ce qui casse `snow sql -f` : on passe donc
par le connecteur Python, qui envoie l'instruction CREATE PROCEDURE en un bloc.

Usage : python scripts/deploy_sproc.py --connection <NOM_CONNEXION>
Prérequis : pip install snowflake-connector-python
"""
import argparse
from pathlib import Path

import snowflake.connector

SQL_FILE = Path(__file__).resolve().parent.parent / "setup" / "optimizer_sproc.sql"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--connection", default="default")
    parser.add_argument("--database", default="FLEET_INTELLIGENCE")
    parser.add_argument("--schema", default="ROUTE_OPTIMIZATION")
    parser.add_argument("--warehouse", default="ROUTING_WH")
    parser.add_argument("--role", default="ROUTE_OPTIMIZATION_ROLE")
    args = parser.parse_args()

    content = SQL_FILE.read_text()
    start = content.find("CREATE OR REPLACE PROCEDURE")
    end = content.rfind("$$;") + 3
    if start < 0 or end < 3:
        raise SystemExit(f"CREATE PROCEDURE introuvable dans {SQL_FILE}")
    grants = content[end:]

    conn = snowflake.connector.connect(connection_name=args.connection)
    try:
        cur = conn.cursor()
        cur.execute(f"USE ROLE {args.role}")
        cur.execute(f"USE WAREHOUSE {args.warehouse}")
        cur.execute(f"USE SCHEMA {args.database}.{args.schema}")
        cur.execute(content[start:end])
        for stmt in grants.split(";"):
            lines = [l for l in stmt.splitlines() if l.strip() and not l.strip().startswith("--")]
            if lines:
                cur.execute("\n".join(lines))
        print("Procedure OPTIMIZE_ROUTES deployee.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
