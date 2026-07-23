from __future__ import annotations

import unittest

try:
    from fastapi import APIRouter
    from smart_alarm_bff.write_routes import _body_hash, _idempotency, register_write_routes
except ModuleNotFoundError as exc:
    _missing_dependency = exc.name
else:
    _missing_dependency = None


@unittest.skipUnless(_missing_dependency is None, f"runtime dependency is not installed: {_missing_dependency}")
class WriteRouteContractTest(unittest.TestCase):
    def test_request_hash_is_canonical(self) -> None:
        self.assertEqual(_body_hash({"b": 2, "a": 1}), _body_hash({"a": 1, "b": 2}))
        self.assertNotEqual(_body_hash({"a": 1}), _body_hash({"a": 2}))

    def test_all_initial_lifecycle_write_paths_are_mounted(self) -> None:
        router = APIRouter()
        register_write_routes(router, object(), object())  # type: ignore[arg-type]
        paths = {route.path for route in router.routes}
        self.assertTrue({
            "/api/v1/system/tenants",
            "/api/v1/system/tenants/{tenant_id}",
            "/api/v1/system/tenants/{tenant_id}/archive",
            "/api/v1/customers",
            "/api/v1/customers/{customer_id}",
            "/api/v1/customers/{customer_id}/archive",
        }.issubset(paths))


if __name__ == "__main__":
    unittest.main()
