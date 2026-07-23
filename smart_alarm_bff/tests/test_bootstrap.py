from __future__ import annotations

import unittest
from uuid import UUID

from smart_alarm_bff.bootstrap import register_system_user
from smart_alarm_bff.config import ConfigError
from smart_alarm_bff.thingsboard import ThingsBoardUser


PLATFORM_USER_ID = UUID("11111111-1111-4111-8111-111111111111")
LOCAL_USER_ID = UUID("22222222-2222-4222-8222-222222222222")
ROLE_ID = UUID("33333333-3333-4333-8333-333333333333")


class Result:
    def __init__(self, row: tuple[UUID] | None = None) -> None:
        self.row = row

    def fetchone(self) -> tuple[UUID] | None:
        return self.row


class Transaction:
    def __enter__(self) -> None:
        return None

    def __exit__(self, *_: object) -> None:
        return None


class Connection:
    def __init__(self) -> None:
        self.calls: list[tuple[str, object]] = []

    def transaction(self) -> Transaction:
        return Transaction()

    def execute(self, sql: str, parameters: object = None) -> Result:
        self.calls.append((sql, parameters))
        if "INSERT INTO smart_alarm.users" in sql:
            return Result((LOCAL_USER_ID,))
        if "FROM smart_alarm.product_roles" in sql:
            return Result((ROLE_ID,))
        return Result()


class BootstrapSystemUserTest(unittest.TestCase):
    def test_registers_verified_identity_and_active_system_role_idempotently(self) -> None:
        connection = Connection()
        user = ThingsBoardUser(
            user_id=PLATFORM_USER_ID,
            username="sysadmin01",
            email=None,
            authority="SYS_ADMIN",
            tenant_id=None,
            customer_id=None,
        )

        self.assertEqual(register_system_user(connection, user), LOCAL_USER_ID)

        statements = "\n".join(sql for sql, _ in connection.calls)
        self.assertIn("ON CONFLICT (thingsboard_user_id) DO UPDATE", statements)
        self.assertIn("role_key = 'SYSTEM_OPERATOR'", statements)
        self.assertIn("WHERE NOT EXISTS", statements)
        self.assertEqual(
            connection.calls[0][1],
            (f"thingsboard:{PLATFORM_USER_ID}", PLATFORM_USER_ID, "sysadmin01", None),
        )

    def test_rejects_scoped_or_non_system_identity(self) -> None:
        user = ThingsBoardUser(
            user_id=PLATFORM_USER_ID,
            username="tenant01",
            email=None,
            authority="TENANT_ADMIN",
            tenant_id=UUID("44444444-4444-4444-8444-444444444444"),
            customer_id=None,
        )
        with self.assertRaisesRegex(ConfigError, "unscoped ThingsBoard SYS_ADMIN"):
            register_system_user(Connection(), user)


if __name__ == "__main__":
    unittest.main()
