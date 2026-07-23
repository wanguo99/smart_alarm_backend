from __future__ import annotations

import unittest

try:
    from fastapi import APIRouter
    from smart_alarm_bff.directory_routes import _page, register_directory_routes
except ModuleNotFoundError as exc:
    _missing_dependency = exc.name
else:
    _missing_dependency = None


@unittest.skipUnless(_missing_dependency is None, f"runtime dependency is not installed: {_missing_dependency}")
class DirectoryRouteContractTest(unittest.TestCase):
    def test_page_contract_is_explicit_and_stable(self) -> None:
        self.assertEqual(_page([]), {"data": [], "totalPages": 0, "totalElements": 0, "hasNext": False})
        self.assertEqual(_page([{"id": "one"}]), {"data": [{"id": "one"}], "totalPages": 1, "totalElements": 1, "hasNext": False})

    def test_all_frontend_directory_paths_are_mounted(self) -> None:
        router = APIRouter()
        register_directory_routes(router, object(), object())  # type: ignore[arg-type]
        paths = {route.path for route in router.routes}
        self.assertTrue({
            "/api/v1/customers",
            "/api/v1/customers/{customer_id}",
            "/api/v1/customers/{customer_id}/members",
            "/api/v1/assets",
            "/api/v1/assets/{asset_id}",
            "/api/v1/assets/{asset_id}/relations",
            "/api/v1/entity-groups",
            "/api/v1/device-profiles",
            "/api/v1/device-management/devices",
            "/api/v1/device-management/assignment-options",
            "/api/v1/system/tenants",
            "/api/v1/system/users",
            "/api/v1/system/role-assignments",
            "/api/v1/system/tenants/{tenant_id}/users",
        }.issubset(paths))


if __name__ == "__main__":
    unittest.main()
