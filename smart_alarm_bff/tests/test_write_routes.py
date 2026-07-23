from __future__ import annotations

import unittest

try:
    from fastapi import APIRouter
    from smart_alarm_bff.policy import ProductPrincipal
    from smart_alarm_bff.write_routes import _account_input, _account_request_hash, _audit, _body_hash, _finish_operation, _idempotency, _outbox, _queue_operation, register_write_routes
except ModuleNotFoundError as exc:
    _missing_dependency = exc.name
else:
    _missing_dependency = None


@unittest.skipUnless(_missing_dependency is None, f"runtime dependency is not installed: {_missing_dependency}")
class WriteRouteContractTest(unittest.TestCase):
    def test_request_hash_is_canonical(self) -> None:
        self.assertEqual(_body_hash({"b": 2, "a": 1}), _body_hash({"a": 1, "b": 2}))
        self.assertNotEqual(_body_hash({"a": 1}), _body_hash({"a": 2}))

    def test_account_input_accepts_phone_without_email_and_never_hashes_password(self) -> None:
        body = {
            "username": "+8613800138000",
            "email": None,
            "initialPassword": "development-password",
            "productRole": "CUSTOMER_VIEWER",
        }
        self.assertEqual(
            _account_input(body, {"CUSTOMER_VIEWER"}),
            ("+8613800138000", None, "development-password", "CUSTOMER_VIEWER", "ACTIVE"),
        )
        self.assertEqual(
            _account_request_hash(body),
            _account_request_hash({**body, "initialPassword": "different-password"}),
        )

    def test_all_initial_lifecycle_write_paths_are_mounted(self) -> None:
        router = APIRouter()
        register_write_routes(router, object(), object())  # type: ignore[arg-type]
        paths = {route.path for route in router.routes}
        self.assertTrue({
            "/api/v1/system/tenants",
            "/api/v1/system/tenants/{tenant_id}",
            "/api/v1/system/tenants/{tenant_id}/archive",
            "/api/v1/system/users",
            "/api/v1/system/users/{user_id}",
            "/api/v1/system/users/{user_id}/archive",
            "/api/v1/system/role-assignments",
            "/api/v1/system/role-assignments/{user_id}",
            "/api/v1/system/role-assignments/{user_id}/archive",
            "/api/v1/customers",
            "/api/v1/customers/{customer_id}",
            "/api/v1/customers/{customer_id}/archive",
            "/api/v1/customers/{customer_id}/members",
            "/api/v1/customers/{customer_id}/members/{member_id}",
            "/api/v1/customers/{customer_id}/members/{member_id}/archive",
            "/api/v1/assets",
            "/api/v1/assets/{asset_id}",
            "/api/v1/assets/{asset_id}/archive",
            "/api/v1/device-profiles",
            "/api/v1/device-profiles/{profile_id}",
            "/api/v1/device-profiles/{profile_id}/archive",
            "/api/v1/entity-groups",
            "/api/v1/entity-groups/{group_id}",
            "/api/v1/entity-groups/{group_id}/archive",
            "/api/v1/entity-groups/{group_id}/restore",
            "/api/v1/entity-groups/{group_id}/members",
        }.issubset(paths))

    def test_audit_and_outbox_execute_independent_inserts(self) -> None:
        class Connection:
            def __init__(self) -> None:
                self.calls: list[tuple[str, tuple[object, ...]]] = []

            async def fetchval(self, statement: str, *_args: object) -> None:
                self.calls.append((statement, _args))
                return None

            async def execute(self, statement: str, *_args: object) -> None:
                self.calls.append((statement, _args))

        from uuid import UUID

        principal = ProductPrincipal(
            local_user_id=UUID("11111111-1111-4111-8111-111111111111"),
            platform_user_id=UUID("22222222-2222-4222-8222-222222222222"),
            authority="TENANT_ADMIN",
            product_role="TENANT_OWNER",
            internal_tenant_id=UUID("33333333-3333-4333-8333-333333333333"),
            platform_tenant_id=UUID("44444444-4444-4444-8444-444444444444"),
            internal_customer_id=None,
            platform_customer_id=None,
            capabilities=frozenset(),
            policy_version=1,
            identity_version=1,
        )
        connection = Connection()
        import asyncio

        asyncio.run(_audit(connection, principal, "request-123", "TESTED", "DEVICE", "device-1", {}))
        self.assertEqual(len(connection.calls), 3)
        self.assertIn("pg_advisory_xact_lock", connection.calls[0][0])
        self.assertIn("INSERT INTO smart_alarm.audit_events", connection.calls[2][0])
        self.assertEqual(connection.calls[2][1][8], {})

        connection.calls.clear()
        payload = {"deviceUid": "device-1"}
        asyncio.run(_outbox(connection, principal.internal_tenant_id, "DEVICE", "device-1", "test.requested", payload))
        self.assertEqual(len(connection.calls), 1)
        self.assertIn("INSERT INTO smart_alarm.outbox_events", connection.calls[0][0])
        self.assertIs(connection.calls[0][1][4], payload)

    def test_operation_results_remain_json_objects_for_the_pool_codec(self) -> None:
        class Connection:
            def __init__(self) -> None:
                self.calls: list[tuple[str, tuple[object, ...]]] = []

            async def execute(self, statement: str, *args: object) -> None:
                self.calls.append((statement, args))

        import asyncio
        from uuid import UUID

        operation_id = UUID("11111111-1111-4111-8111-111111111111")
        result = {"status": "SUCCEEDED", "tenant": {"id": "tenant-1"}}
        connection = Connection()

        asyncio.run(_finish_operation(connection, operation_id, result, "tenant-1"))
        asyncio.run(_queue_operation(connection, operation_id, result, "tenant-1"))

        self.assertEqual(len(connection.calls), 2)
        self.assertIs(connection.calls[0][1][1], result)
        self.assertIs(connection.calls[1][1][1], result)


if __name__ == "__main__":
    unittest.main()
