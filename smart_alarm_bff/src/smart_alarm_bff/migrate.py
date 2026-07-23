"""Checksum-protected forward-only PostgreSQL migration runner."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path

from .config import ConfigError, _port, _readable_file, _required, read_secret


def migration_directory() -> Path:
    configured = os.environ.get("SMART_ALARM_MIGRATIONS_DIR", "").strip()
    return Path(configured) if configured else Path(__file__).resolve().parents[2] / "migrations"


def load_migrations(directory: Path) -> list[tuple[str, str, str]]:
    if not directory.is_dir():
        raise ConfigError("SMART_ALARM_MIGRATIONS_DIR must reference a directory")
    migrations: list[tuple[str, str, str]] = []
    for path in sorted(directory.glob("[0-9][0-9][0-9][0-9]_*.sql")):
        sql = path.read_text(encoding="utf-8")
        if not sql.strip():
            raise ConfigError(f"migration {path.name} is empty")
        migrations.append((path.name, hashlib.sha256(sql.encode("utf-8")).hexdigest(), sql))
    if not migrations:
        raise ConfigError("no migrations were found")
    return migrations


def run() -> int:
    import psycopg

    env = os.environ
    if _required(env, "SMART_ALARM_DATABASE_SSLMODE") != "verify-full":
        raise ConfigError("SMART_ALARM_DATABASE_SSLMODE must be verify-full")
    password = read_secret(env, "SMART_ALARM_MIGRATION_DATABASE_PASSWORD", minimum_bytes=16).decode("utf-8")
    migrations = load_migrations(migration_directory())
    with psycopg.connect(
        host=_required(env, "SMART_ALARM_DATABASE_HOST"),
        port=_port(env, "SMART_ALARM_DATABASE_PORT"),
        dbname=_required(env, "SMART_ALARM_DATABASE_NAME"),
        user=_required(env, "SMART_ALARM_MIGRATION_DATABASE_USER"),
        password=password,
        sslmode="verify-full",
        sslrootcert=str(_readable_file(env, "SMART_ALARM_DATABASE_CA_FILE")),
        application_name="smart-alarm-migrate",
        connect_timeout=5,
    ) as connection:
        connection.execute("SELECT pg_advisory_lock(hashtextextended('smart-alarm-schema-migrations', 0))")
        try:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS public.smart_alarm_schema_migrations (
                    name text PRIMARY KEY,
                    checksum char(64) NOT NULL,
                    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
                )
                """
            )
            connection.commit()
            applied = dict(connection.execute("SELECT name, checksum FROM public.smart_alarm_schema_migrations").fetchall())
            for name, checksum, sql in migrations:
                if name in applied:
                    if applied[name].strip() != checksum:
                        raise RuntimeError(f"migration checksum mismatch: {name}")
                    continue
                with connection.transaction():
                    connection.execute(sql)
                    connection.execute(
                        "INSERT INTO public.smart_alarm_schema_migrations (name, checksum) VALUES (%s, %s)",
                        (name, checksum),
                    )
                print(f"applied {name}")
        finally:
            connection.execute("SELECT pg_advisory_unlock(hashtextextended('smart-alarm-schema-migrations', 0))")
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
