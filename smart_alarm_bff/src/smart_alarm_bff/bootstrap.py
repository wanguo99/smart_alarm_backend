"""One-time registration of a verified ThingsBoard SYS_ADMIN in the product directory."""

from __future__ import annotations

import asyncio
import os
from typing import Any
from uuid import UUID

from .config import ConfigError, LocalSettings, ProductionSettings, _required, load_settings, read_secret
from .policy import PolicyError
from .thingsboard import ThingsBoardClient, ThingsBoardError, ThingsBoardUser, normalize_username


def register_system_user(connection: Any, user: ThingsBoardUser) -> UUID:
    if user.authority != "SYS_ADMIN" or user.tenant_id is not None or user.customer_id is not None:
        raise ConfigError("bootstrap identity must be an unscoped ThingsBoard SYS_ADMIN")

    with connection.transaction():
        row = connection.execute(
            """
            INSERT INTO smart_alarm.users
                (oidc_subject, thingsboard_user_id, username, email, authority,
                 tenant_id, customer_id, status)
            VALUES (%s, %s, %s, %s, 'SYS_ADMIN', NULL, NULL, 'ACTIVE')
            ON CONFLICT (thingsboard_user_id) DO UPDATE
            SET username = EXCLUDED.username,
                email = EXCLUDED.email,
                authority = 'SYS_ADMIN',
                tenant_id = NULL,
                customer_id = NULL,
                status = 'ACTIVE',
                archived_at = NULL,
                identity_version = smart_alarm.users.identity_version +
                    CASE WHEN (
                        smart_alarm.users.username,
                        smart_alarm.users.email,
                        smart_alarm.users.authority,
                        smart_alarm.users.tenant_id,
                        smart_alarm.users.customer_id,
                        smart_alarm.users.status
                    ) IS DISTINCT FROM (
                        EXCLUDED.username,
                        EXCLUDED.email,
                        'SYS_ADMIN'::text,
                        NULL::uuid,
                        NULL::uuid,
                        'ACTIVE'::text
                    ) THEN 1 ELSE 0 END,
                updated_at = clock_timestamp()
            RETURNING id
            """,
            (f"thingsboard:{user.user_id}", user.user_id, user.username, user.email),
        ).fetchone()
        if row is None:
            raise RuntimeError("system user registration returned no identifier")
        local_user_id = row[0]

        role = connection.execute(
            """
            SELECT id
            FROM smart_alarm.product_roles
            WHERE role_key = 'SYSTEM_OPERATOR'
              AND authority = 'SYS_ADMIN'
              AND status = 'ACTIVE'
            """
        ).fetchone()
        if role is None:
            raise RuntimeError("active SYSTEM_OPERATOR product role is missing")
        role_id = role[0]

        connection.execute(
            """
            UPDATE smart_alarm.role_assignments
            SET status = 'REVOKED', revoked_at = clock_timestamp(), version = version + 1
            WHERE user_id = %s AND status = 'ACTIVE' AND role_id <> %s
            """,
            (local_user_id, role_id),
        )
        connection.execute(
            """
            INSERT INTO smart_alarm.role_assignments
                (user_id, role_id, tenant_id, customer_id, status, granted_by)
            SELECT %s, %s, NULL, NULL, 'ACTIVE', %s
            WHERE NOT EXISTS (
                SELECT 1 FROM smart_alarm.role_assignments
                WHERE user_id = %s AND role_id = %s AND status = 'ACTIVE'
            )
            """,
            (local_user_id, role_id, local_user_id, local_user_id, role_id),
        )
    return local_user_id


async def authenticate_system_user(
    settings: ProductionSettings | LocalSettings,
    username: str,
    password: str,
) -> ThingsBoardUser:
    client = ThingsBoardClient(
        settings.thingsboard_url,
        verify=str(settings.thingsboard_ca_file) if settings.thingsboard_ca_file else True,
    )
    try:
        access_token = await client.login(username, password)
        user = await client.current_user(access_token)
    finally:
        await client.close()
    if user.authority != "SYS_ADMIN" or user.tenant_id is not None or user.customer_id is not None:
        raise ConfigError("SMART_ALARM_BOOTSTRAP_USERNAME must identify a ThingsBoard SYS_ADMIN")
    return user


def run() -> int:
    import psycopg

    settings = load_settings()
    try:
        username = normalize_username(_required(os.environ, "SMART_ALARM_BOOTSTRAP_USERNAME"))
    except PolicyError as exc:
        raise ConfigError("SMART_ALARM_BOOTSTRAP_USERNAME is invalid") from exc
    try:
        password = read_secret(os.environ, "SMART_ALARM_BOOTSTRAP_PASSWORD").decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ConfigError("SMART_ALARM_BOOTSTRAP_PASSWORD must be UTF-8") from exc

    try:
        user = asyncio.run(authenticate_system_user(settings, username, password))
    except ThingsBoardError as exc:
        raise ConfigError(f"ThingsBoard bootstrap authentication failed: {exc.code}") from exc

    connection_options: dict[str, object] = {
        "host": settings.database_host,
        "port": settings.database_port,
        "dbname": settings.database_name,
        "user": settings.database_user,
        "password": settings.database_password.decode("utf-8"),
        "application_name": "smart-alarm-bootstrap-system-user",
        "connect_timeout": 5,
        "sslmode": "verify-full" if settings.database_tls else "disable",
    }
    if settings.database_ca_file:
        connection_options["sslrootcert"] = str(settings.database_ca_file)
    with psycopg.connect(**connection_options) as connection:
        local_user_id = register_system_user(connection, user)
    print(f"registered SYS_ADMIN {user.username} ({user.user_id}) as product user {local_user_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
