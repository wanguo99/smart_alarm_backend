"""Transactional Tenant/Customer lifecycle routes.

The handler performs the product mutation, idempotency record and audit event
in one PostgreSQL transaction. ThingsBoard side effects are deliberately left
to the outbox/adapter stage and are never performed in a browser request.
"""

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import re
from typing import Any, Awaitable, Callable
from uuid import UUID

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from .directory_routes import DirectoryError, _error, _scoped_connection
from .policy import PolicyError, ProductPrincipal
from .session import SessionContext, SessionError, SessionService


_IDEMPOTENCY = re.compile(r"^[A-Za-z0-9._:-]{8,255}$")


class WriteError(RuntimeError):
    def __init__(self, code: str, status_code: int = 400) -> None:
        super().__init__(code)
        self.code = code
        self.status_code = status_code


def _write_error(exc: WriteError) -> JSONResponse:
    return JSONResponse(status_code=exc.status_code, content={"error": {"code": exc.code, "message": "write request failed"}})


def _body_hash(body: dict[str, object]) -> bytes:
    encoded = json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    return hashlib.sha256(encoded).digest()


def _json_object(value: object) -> dict[str, object]:
    if isinstance(value, dict):
        return value
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError:
            parsed = None
        if isinstance(parsed, dict):
            return parsed
    return {}


def _name(body: dict[str, object], maximum: int = 255) -> str:
    value = body.get("name")
    if not isinstance(value, str) or not value or len(value) > maximum or value != value.strip():
        raise WriteError("invalid_name")
    return value


def _idempotency(request: Request) -> str:
    value = request.headers.get("Idempotency-Key", "")
    if not _IDEMPOTENCY.fullmatch(value):
        raise WriteError("idempotency_key_required")
    return value


async def _begin_operation(connection: Any, principal: ProductPrincipal, key: str, operation_type: str, resource_type: str, request_hash: bytes) -> tuple[UUID, dict[str, object] | None]:
    row = await connection.fetchrow(
        """
        INSERT INTO smart_alarm.operations (tenant_id, customer_id, actor_user_id, operation_type, resource_type, idempotency_key, request_hash, state)
        VALUES ($1, $2, $3, $4, $5, $6, $7, 'PENDING')
        ON CONFLICT (tenant_id, operation_type, idempotency_key) DO NOTHING
        RETURNING id
        """,
        principal.internal_tenant_id, principal.internal_customer_id, principal.local_user_id,
        operation_type, resource_type, key, request_hash,
    )
    if row is not None:
        return row["id"], None
    existing = await connection.fetchrow(
        "SELECT id, request_hash, state, result FROM smart_alarm.operations WHERE tenant_id IS NOT DISTINCT FROM $1 AND operation_type = $2 AND idempotency_key = $3",
        principal.internal_tenant_id, operation_type, key,
    )
    if existing is None or bytes(existing["request_hash"]) != request_hash:
        raise WriteError("idempotency_conflict", 409)
    if existing["state"] == "SUCCEEDED":
        return existing["id"], _json_object(existing["result"])
    raise WriteError("operation_in_progress", 409)


async def _finish_operation(connection: Any, operation_id: UUID, result: dict[str, object], resource_id: str | None = None) -> None:
    await connection.execute(
        "UPDATE smart_alarm.operations SET state = 'SUCCEEDED', result = $2::jsonb, resource_id = $3, finished_at = clock_timestamp(), updated_at = clock_timestamp(), version = version + 1 WHERE id = $1",
        operation_id, json.dumps(result, separators=(",", ":"), ensure_ascii=True), resource_id,
    )


async def _audit(connection: Any, principal: ProductPrincipal, request_id: str, action: str, resource_type: str, resource_id: str | None, detail: dict[str, object]) -> None:
    previous = await connection.fetchval(
        "SELECT event_hash FROM smart_alarm.audit_events WHERE tenant_id IS NOT DISTINCT FROM $1 ORDER BY id DESC LIMIT 1",
        principal.internal_tenant_id,
    )
    canonical = json.dumps({"requestId": request_id, "action": action, "resourceType": resource_type, "resourceId": resource_id, "detail": detail}, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    event_hash = hashlib.sha256((bytes(previous) if previous else b"") + canonical).digest()
    await connection.execute(
        "INSERT INTO smart_alarm.audit_events (tenant_id, customer_id, actor_user_id, request_id, action, resource_type, resource_id, outcome, detail, previous_hash, event_hash) VALUES ($1, $2, $3, $4, $5, $6, $7, 'SUCCEEDED', $8::jsonb, $9, $10)",
        principal.internal_tenant_id, principal.internal_customer_id, principal.local_user_id, request_id, action, resource_type, resource_id,
        json.dumps(detail, separators=(",", ":"), ensure_ascii=True), previous, event_hash,
    )


async def _guard(request: Request, sessions: SessionService, database: Callable[[], Awaitable[Any]], capability: str) -> ProductPrincipal:
    context = getattr(request.state, "session_context", None)
    if not isinstance(context, SessionContext):
        try:
            context = await sessions.resolve(await database(), request.cookies.get("__Host-smart_alarm_session"))
        except SessionError as exc:
            raise WriteError(exc.code, exc.status_code) from exc
    try:
        context.principal.require(capability)
    except PolicyError as exc:
        raise WriteError("capability_required", 403) from exc
    try:
        await sessions.require_csrf(await database(), request.cookies.get("__Host-smart_alarm_session"), request.headers.get("X-CSRF-Token"))
    except SessionError as exc:
        raise WriteError(exc.code, exc.status_code) from exc
    request.state.session_context = context
    return context.principal


def register_write_routes(router: APIRouter, sessions: SessionService, database: Callable[[], Awaitable[Any]]) -> None:
    @router.post("/api/v1/system/tenants")
    async def create_tenant(request: Request, body: dict[str, object]):
        try:
            principal = await _guard(request, sessions, database, "system:tenants:write")
            name = _name(body)
            key = _idempotency(request)
            async with _scoped_connection(await database(), principal) as connection:
                operation_id, replay = await _begin_operation(connection, principal, key, "tenant-create", "TENANT", _body_hash(body))
                if replay is not None:
                    return replay
                row = await connection.fetchrow("INSERT INTO smart_alarm.tenants (name) VALUES ($1) RETURNING id, name", name)
                result = {"operationId": str(operation_id), "kind": "system-tenant-create", "status": "SUCCEEDED", "tenant": {"id": str(row["id"]), "name": row["name"]}}
                await _finish_operation(connection, operation_id, result, str(row["id"]))
                await _audit(connection, principal, key, "TENANT_CREATED", "TENANT", str(row["id"]), {"name": name})
            return result
        except WriteError as exc:
            return _write_error(exc)

    @router.patch("/api/v1/system/tenants/{tenant_id}")
    async def update_tenant(tenant_id: str, request: Request, body: dict[str, object]):
        try:
            principal = await _guard(request, sessions, database, "system:tenants:write")
            name = _name(body)
            key = _idempotency(request)
            tenant_uuid = UUID(tenant_id)
            async with _scoped_connection(await database(), principal) as connection:
                operation_id, replay = await _begin_operation(connection, principal, key, "tenant-update", "TENANT", _body_hash({"tenantId": tenant_id, **body}))
                if replay is not None:
                    return replay
                row = await connection.fetchrow("UPDATE smart_alarm.tenants SET name = $2, version = version + 1, updated_at = clock_timestamp() WHERE id = $1 AND status = 'ACTIVE' RETURNING id, name", tenant_uuid, name)
                if row is None:
                    raise WriteError("not_found", 404)
                result = {"operationId": str(operation_id), "kind": "system-tenant-update", "status": "SUCCEEDED", "tenant": {"id": str(row["id"]), "name": row["name"]}}
                await _finish_operation(connection, operation_id, result, tenant_id)
                await _audit(connection, principal, key, "TENANT_UPDATED", "TENANT", tenant_id, {"name": name})
            return result
        except (WriteError, ValueError) as exc:
            return _write_error(exc if isinstance(exc, WriteError) else WriteError("not_found", 404))

    @router.post("/api/v1/system/tenants/{tenant_id}/archive")
    async def archive_tenant(tenant_id: str, request: Request):
        try:
            principal = await _guard(request, sessions, database, "system:tenants:write")
            key = _idempotency(request)
            tenant_uuid = UUID(tenant_id)
            async with _scoped_connection(await database(), principal) as connection:
                operation_id, replay = await _begin_operation(connection, principal, key, "tenant-archive", "TENANT", _body_hash({"tenantId": tenant_id}))
                if replay is not None:
                    return replay
                count = await connection.fetchval("SELECT count(*) FROM smart_alarm.customers WHERE tenant_id = $1 AND status = 'ACTIVE'", tenant_uuid)
                if count:
                    raise WriteError("tenant_has_customers", 409)
                row = await connection.fetchrow("UPDATE smart_alarm.tenants SET status = 'ARCHIVED', archived_at = clock_timestamp(), version = version + 1, updated_at = clock_timestamp() WHERE id = $1 AND status = 'ACTIVE' RETURNING id, name, archived_at", tenant_uuid)
                if row is None:
                    raise WriteError("not_found", 404)
                result = {"operationId": str(operation_id), "kind": "system-tenant-archive", "status": "SUCCEEDED", "tenant": {"id": str(row["id"]), "name": row["name"], "archivedAt": int(row["archived_at"].timestamp() * 1000)}}
                await _finish_operation(connection, operation_id, result, tenant_id)
                await _audit(connection, principal, key, "TENANT_ARCHIVED", "TENANT", tenant_id, {})
            return result
        except (WriteError, ValueError) as exc:
            return _write_error(exc if isinstance(exc, WriteError) else WriteError("not_found", 404))

    @router.post("/api/v1/customers")
    async def create_customer(request: Request, body: dict[str, object]):
        try:
            principal = await _guard(request, sessions, database, "customers:write")
            if principal.internal_tenant_id is None:
                raise WriteError("tenant_scope_required", 403)
            name = _name(body, 255)
            key = _idempotency(request)
            async with _scoped_connection(await database(), principal) as connection:
                operation_id, replay = await _begin_operation(connection, principal, key, "customer-create", "CUSTOMER", _body_hash(body))
                if replay is not None:
                    return replay
                row = await connection.fetchrow("INSERT INTO smart_alarm.customers (tenant_id, name) VALUES ($1, $2) RETURNING id, name", principal.internal_tenant_id, name)
                result = {"operationId": str(operation_id), "kind": "customer-create", "status": "SUCCEEDED", "customer": {"id": str(row["id"]), "name": row["name"], "deviceCount": 0, "assetCount": 0}}
                await _finish_operation(connection, operation_id, result, str(row["id"]))
                await _audit(connection, principal, key, "CUSTOMER_CREATED", "CUSTOMER", str(row["id"]), {"name": name})
            return result
        except WriteError as exc:
            return _write_error(exc)

    @router.patch("/api/v1/customers/{customer_id}")
    async def update_customer(customer_id: str, request: Request, body: dict[str, object]):
        try:
            principal = await _guard(request, sessions, database, "customers:write")
            if principal.internal_tenant_id is None:
                raise WriteError("tenant_scope_required", 403)
            name = _name(body, 255)
            key = _idempotency(request)
            customer_uuid = UUID(customer_id)
            async with _scoped_connection(await database(), principal) as connection:
                operation_id, replay = await _begin_operation(connection, principal, key, "customer-update", "CUSTOMER", _body_hash({"customerId": customer_id, **body}))
                if replay is not None:
                    return replay
                row = await connection.fetchrow("UPDATE smart_alarm.customers SET name = $3, version = version + 1, updated_at = clock_timestamp() WHERE tenant_id = $1 AND id = $2 AND status = 'ACTIVE' RETURNING id, name", principal.internal_tenant_id, customer_uuid, name)
                if row is None:
                    raise WriteError("not_found", 404)
                result = {"operationId": str(operation_id), "kind": "customer-update", "status": "SUCCEEDED", "customer": {"id": str(row["id"]), "name": row["name"], "deviceCount": 0, "assetCount": 0}}
                await _finish_operation(connection, operation_id, result, customer_id)
                await _audit(connection, principal, key, "CUSTOMER_UPDATED", "CUSTOMER", customer_id, {"name": name})
            return result
        except (WriteError, ValueError) as exc:
            return _write_error(exc if isinstance(exc, WriteError) else WriteError("not_found", 404))

    @router.post("/api/v1/customers/{customer_id}/archive")
    async def archive_customer(customer_id: str, request: Request):
        try:
            principal = await _guard(request, sessions, database, "customers:write")
            customer_uuid = UUID(customer_id)
            key = _idempotency(request)
            async with _scoped_connection(await database(), principal) as connection:
                operation_id, replay = await _begin_operation(connection, principal, key, "customer-archive", "CUSTOMER", _body_hash({"customerId": customer_id}))
                if replay is not None:
                    return replay
                active_devices = await connection.fetchval("SELECT count(*) FROM smart_alarm.devices WHERE tenant_id = $1 AND customer_id = $2 AND lifecycle_state <> 'RETIRED'", principal.internal_tenant_id, customer_uuid)
                active_members = await connection.fetchval("SELECT count(*) FROM smart_alarm.users WHERE tenant_id = $1 AND customer_id = $2 AND status <> 'ARCHIVED'", principal.internal_tenant_id, customer_uuid)
                if active_devices or active_members:
                    raise WriteError("customer_has_resources", 409)
                row = await connection.fetchrow("UPDATE smart_alarm.customers SET status = 'ARCHIVED', archived_at = clock_timestamp(), version = version + 1, updated_at = clock_timestamp() WHERE tenant_id = $1 AND id = $2 AND status = 'ACTIVE' RETURNING id, name, archived_at", principal.internal_tenant_id, customer_uuid)
                if row is None:
                    raise WriteError("not_found", 404)
                result = {"operationId": str(operation_id), "kind": "customer-archive", "status": "SUCCEEDED", "customer": {"id": str(row["id"]), "name": row["name"], "deviceCount": 0, "assetCount": 0}}
                await _finish_operation(connection, operation_id, result, customer_id)
                await _audit(connection, principal, key, "CUSTOMER_ARCHIVED", "CUSTOMER", customer_id, {})
            return result
        except (WriteError, ValueError) as exc:
            return _write_error(exc if isinstance(exc, WriteError) else WriteError("not_found", 404))


def mount_write_routes(app: Any, sessions: SessionService, database: Callable[[], Awaitable[Any]]) -> None:
    router = APIRouter()
    register_write_routes(router, sessions, database)
    app.include_router(router)
