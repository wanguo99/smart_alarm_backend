CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS smart_alarm;

CREATE FUNCTION smart_alarm.current_tenant_id() RETURNS uuid
LANGUAGE sql STABLE PARALLEL SAFE
AS $$
    SELECT NULLIF(current_setting('smart_alarm.tenant_id', true), '')::uuid
$$;

CREATE TABLE smart_alarm.tenants (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    thingsboard_tenant_id uuid UNIQUE,
    name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 255),
    status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'ARCHIVED')),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    archived_at timestamptz,
    UNIQUE (id, status),
    CHECK ((status = 'ARCHIVED') = (archived_at IS NOT NULL))
);

CREATE UNIQUE INDEX tenants_active_name_uq ON smart_alarm.tenants (lower(name)) WHERE status = 'ACTIVE';

CREATE TABLE smart_alarm.customers (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES smart_alarm.tenants(id),
    thingsboard_customer_id uuid,
    name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 255),
    status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'ARCHIVED')),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    archived_at timestamptz,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, thingsboard_customer_id),
    CHECK ((status = 'ARCHIVED') = (archived_at IS NOT NULL))
);

CREATE UNIQUE INDEX customers_active_name_uq ON smart_alarm.customers (tenant_id, lower(name)) WHERE status = 'ACTIVE';

CREATE TABLE smart_alarm.users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    oidc_subject text NOT NULL UNIQUE CHECK (length(oidc_subject) BETWEEN 1 AND 512),
    thingsboard_user_id uuid UNIQUE,
    email text NOT NULL CHECK (email = lower(email) AND position('@' IN email) > 1),
    authority text NOT NULL CHECK (authority IN ('SYS_ADMIN', 'TENANT_ADMIN', 'CUSTOMER_USER')),
    tenant_id uuid REFERENCES smart_alarm.tenants(id),
    customer_id uuid,
    status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('INVITED', 'ACTIVE', 'SUSPENDED', 'ARCHIVED')),
    identity_version bigint NOT NULL DEFAULT 1 CHECK (identity_version > 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    archived_at timestamptz,
    UNIQUE (tenant_id, email),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES smart_alarm.customers(tenant_id, id),
    CHECK (
        (authority = 'SYS_ADMIN' AND tenant_id IS NULL AND customer_id IS NULL)
        OR (authority = 'TENANT_ADMIN' AND tenant_id IS NOT NULL AND customer_id IS NULL)
        OR (authority = 'CUSTOMER_USER' AND tenant_id IS NOT NULL AND customer_id IS NOT NULL)
    ),
    CHECK ((status = 'ARCHIVED') = (archived_at IS NOT NULL))
);

CREATE UNIQUE INDEX users_active_email_uq ON smart_alarm.users (lower(email)) WHERE status <> 'ARCHIVED';

CREATE TABLE smart_alarm.product_roles (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    role_key text NOT NULL UNIQUE CHECK (role_key ~ '^[A-Z][A-Z0-9_]{2,63}$'),
    authority text NOT NULL CHECK (authority IN ('SYS_ADMIN', 'TENANT_ADMIN', 'CUSTOMER_USER')),
    capabilities jsonb NOT NULL CHECK (jsonb_typeof(capabilities) = 'array'),
    policy_version bigint NOT NULL CHECK (policy_version > 0),
    status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'REVOKED')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE smart_alarm.role_assignments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES smart_alarm.users(id),
    role_id uuid NOT NULL REFERENCES smart_alarm.product_roles(id),
    tenant_id uuid REFERENCES smart_alarm.tenants(id),
    customer_id uuid,
    status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'REVOKED')),
    granted_by uuid REFERENCES smart_alarm.users(id),
    granted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    revoked_at timestamptz,
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES smart_alarm.customers(tenant_id, id),
    CHECK ((status = 'REVOKED') = (revoked_at IS NOT NULL))
);

CREATE UNIQUE INDEX role_assignments_active_user_uq ON smart_alarm.role_assignments (user_id) WHERE status = 'ACTIVE';

CREATE TABLE smart_alarm.device_inventory (
    device_uid uuid PRIMARY KEY,
    serial_number text NOT NULL UNIQUE CHECK (serial_number ~ '^[A-Za-z0-9][A-Za-z0-9._-]{5,63}$'),
    claim_token_hash bytea NOT NULL CHECK (octet_length(claim_token_hash) = 32),
    claim_expires_at timestamptz NOT NULL,
    claim_consumed_at timestamptz,
    factory_batch text NOT NULL CHECK (length(factory_batch) BETWEEN 1 AND 128),
    hardware_model text NOT NULL CHECK (length(hardware_model) BETWEEN 1 AND 128),
    identity_version bigint NOT NULL DEFAULT 1 CHECK (identity_version > 0),
    status text NOT NULL DEFAULT 'UNCLAIMED' CHECK (status IN ('UNCLAIMED', 'CLAIMED', 'BLOCKED')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE smart_alarm.device_profiles (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES smart_alarm.tenants(id),
    thingsboard_profile_id uuid,
    name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 255),
    is_default boolean NOT NULL DEFAULT false,
    status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'ARCHIVED')),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    archived_at timestamptz,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, thingsboard_profile_id),
    CHECK ((status = 'ARCHIVED') = (archived_at IS NOT NULL))
);

CREATE UNIQUE INDEX device_profiles_active_name_uq ON smart_alarm.device_profiles (tenant_id, lower(name)) WHERE status = 'ACTIVE';
CREATE UNIQUE INDEX device_profiles_one_default_uq ON smart_alarm.device_profiles (tenant_id) WHERE is_default AND status = 'ACTIVE';

CREATE TABLE smart_alarm.assets (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES smart_alarm.tenants(id),
    customer_id uuid,
    thingsboard_asset_id uuid,
    parent_asset_id uuid,
    name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 255),
    asset_type text NOT NULL DEFAULT 'SITE' CHECK (length(asset_type) BETWEEN 1 AND 64),
    status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'ARCHIVED')),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    archived_at timestamptz,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, thingsboard_asset_id),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES smart_alarm.customers(tenant_id, id),
    FOREIGN KEY (tenant_id, parent_asset_id) REFERENCES smart_alarm.assets(tenant_id, id),
    CHECK (parent_asset_id IS NULL OR parent_asset_id <> id),
    CHECK ((status = 'ARCHIVED') = (archived_at IS NOT NULL))
);

CREATE UNIQUE INDEX assets_active_name_uq ON smart_alarm.assets (tenant_id, customer_id, lower(name)) WHERE status = 'ACTIVE';

CREATE TABLE smart_alarm.business_groups (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES smart_alarm.tenants(id),
    customer_id uuid,
    name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 128),
    status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'ARCHIVED')),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    archived_at timestamptz,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES smart_alarm.customers(tenant_id, id),
    CHECK ((status = 'ARCHIVED') = (archived_at IS NOT NULL))
);

CREATE UNIQUE INDEX business_groups_active_name_uq ON smart_alarm.business_groups (tenant_id, customer_id, lower(name)) WHERE status = 'ACTIVE';

CREATE TABLE smart_alarm.devices (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES smart_alarm.tenants(id),
    device_uid uuid NOT NULL UNIQUE REFERENCES smart_alarm.device_inventory(device_uid),
    thingsboard_device_id uuid NOT NULL UNIQUE,
    customer_id uuid,
    asset_id uuid,
    business_group_id uuid,
    device_profile_id uuid NOT NULL,
    technical_name text NOT NULL UNIQUE CHECK (technical_name ~ '^stc-[0-9a-f-]{36}$'),
    display_name text NOT NULL CHECK (length(btrim(display_name)) BETWEEN 1 AND 255),
    lifecycle_state text NOT NULL CHECK (lifecycle_state IN ('ACTIVATING', 'ACTIVE', 'RETIRING', 'RETIRED', 'ACTIVATION_FAILED', 'RETIREMENT_FAILED')),
    credential_version bigint NOT NULL DEFAULT 1 CHECK (credential_version > 0),
    credential_secret_ref text NOT NULL CHECK (length(credential_secret_ref) BETWEEN 1 AND 1024),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    retired_at timestamptz,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES smart_alarm.customers(tenant_id, id),
    FOREIGN KEY (tenant_id, asset_id) REFERENCES smart_alarm.assets(tenant_id, id),
    FOREIGN KEY (tenant_id, business_group_id) REFERENCES smart_alarm.business_groups(tenant_id, id),
    FOREIGN KEY (tenant_id, device_profile_id) REFERENCES smart_alarm.device_profiles(tenant_id, id),
    CHECK ((lifecycle_state = 'RETIRED') = (retired_at IS NOT NULL))
);

CREATE INDEX devices_scope_idx ON smart_alarm.devices (tenant_id, customer_id, lifecycle_state, id);
CREATE INDEX devices_asset_idx ON smart_alarm.devices (tenant_id, asset_id) WHERE asset_id IS NOT NULL;

CREATE TABLE smart_alarm.entity_groups (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES smart_alarm.tenants(id),
    customer_id uuid,
    name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 128),
    entity_type text NOT NULL CHECK (entity_type IN ('DEVICE', 'ASSET')),
    status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'ARCHIVED')),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    archived_at timestamptz,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES smart_alarm.customers(tenant_id, id),
    CHECK ((status = 'ARCHIVED') = (archived_at IS NOT NULL))
);

CREATE UNIQUE INDEX entity_groups_active_name_uq ON smart_alarm.entity_groups (tenant_id, customer_id, entity_type, lower(name)) WHERE status = 'ACTIVE';

CREATE TABLE smart_alarm.entity_group_members (
    tenant_id uuid NOT NULL REFERENCES smart_alarm.tenants(id),
    group_id uuid NOT NULL,
    entity_type text NOT NULL CHECK (entity_type IN ('DEVICE', 'ASSET')),
    entity_id uuid NOT NULL,
    added_by uuid NOT NULL REFERENCES smart_alarm.users(id),
    added_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id, group_id, entity_id),
    FOREIGN KEY (tenant_id, group_id) REFERENCES smart_alarm.entity_groups(tenant_id, id)
);

CREATE TABLE smart_alarm.entity_relations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES smart_alarm.tenants(id),
    from_type text NOT NULL CHECK (from_type = 'ASSET'),
    from_id uuid NOT NULL,
    to_type text NOT NULL CHECK (to_type IN ('ASSET', 'DEVICE')),
    to_id uuid NOT NULL,
    relation_type text NOT NULL CHECK (relation_type IN ('Contains', 'COMMON')),
    thingsboard_synced_at timestamptz,
    status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'PENDING_CREATE', 'PENDING_DELETE', 'ERROR')),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (tenant_id, from_type, from_id, to_type, to_id, relation_type),
    FOREIGN KEY (tenant_id, from_id) REFERENCES smart_alarm.assets(tenant_id, id)
);

CREATE TABLE smart_alarm.http_sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES smart_alarm.users(id),
    tenant_id uuid REFERENCES smart_alarm.tenants(id),
    customer_id uuid,
    session_digest bytea NOT NULL UNIQUE CHECK (octet_length(session_digest) = 32),
    csrf_digest bytea NOT NULL CHECK (octet_length(csrf_digest) = 32),
    platform_token_ciphertext bytea NOT NULL,
    platform_token_key_version integer NOT NULL CHECK (platform_token_key_version > 0),
    policy_version bigint NOT NULL CHECK (policy_version > 0),
    identity_version bigint NOT NULL CHECK (identity_version > 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    last_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    FOREIGN KEY (tenant_id, customer_id) REFERENCES smart_alarm.customers(tenant_id, id),
    CHECK (expires_at > created_at)
);

CREATE INDEX http_sessions_active_idx ON smart_alarm.http_sessions (user_id, expires_at) WHERE revoked_at IS NULL;

CREATE TABLE smart_alarm.operations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid REFERENCES smart_alarm.tenants(id),
    customer_id uuid,
    actor_user_id uuid NOT NULL REFERENCES smart_alarm.users(id),
    operation_type text NOT NULL CHECK (operation_type ~ '^[a-z][a-z0-9-]{2,63}$'),
    resource_type text NOT NULL CHECK (length(resource_type) BETWEEN 1 AND 64),
    resource_id text,
    idempotency_key text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 255),
    request_hash bytea NOT NULL CHECK (octet_length(request_hash) = 32),
    state text NOT NULL CHECK (state IN ('PENDING', 'QUEUED', 'SUCCEEDED', 'FAILED', 'CANCELLED', 'OUTCOME_UNKNOWN')),
    result jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(result) = 'object'),
    error_code text,
    parent_operation_id uuid REFERENCES smart_alarm.operations(id),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    finished_at timestamptz,
    FOREIGN KEY (tenant_id, customer_id) REFERENCES smart_alarm.customers(tenant_id, id),
    UNIQUE NULLS NOT DISTINCT (tenant_id, operation_type, idempotency_key)
);

CREATE INDEX operations_pending_idx ON smart_alarm.operations (tenant_id, state, created_at) WHERE state IN ('PENDING', 'QUEUED', 'OUTCOME_UNKNOWN');

CREATE TABLE smart_alarm.command_approvals (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES smart_alarm.tenants(id),
    customer_id uuid,
    device_id uuid NOT NULL,
    command_type text NOT NULL CHECK (command_type = 'reboot'),
    reason text NOT NULL CHECK (length(btrim(reason)) BETWEEN 8 AND 500),
    requester_user_id uuid NOT NULL REFERENCES smart_alarm.users(id),
    decision_user_id uuid REFERENCES smart_alarm.users(id),
    status text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED', 'EXPIRED', 'CONSUMED')),
    expires_at timestamptz NOT NULL,
    decided_at timestamptz,
    consumed_operation_id uuid REFERENCES smart_alarm.operations(id),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES smart_alarm.customers(tenant_id, id),
    FOREIGN KEY (tenant_id, device_id) REFERENCES smart_alarm.devices(tenant_id, id),
    CHECK (requester_user_id IS DISTINCT FROM decision_user_id)
);

CREATE INDEX command_approvals_pending_idx ON smart_alarm.command_approvals (tenant_id, expires_at) WHERE status = 'PENDING';

CREATE TABLE smart_alarm.command_batches (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES smart_alarm.tenants(id),
    customer_id uuid,
    operation_id uuid NOT NULL UNIQUE REFERENCES smart_alarm.operations(id),
    command_type text NOT NULL CHECK (command_type IN ('ping', 'health')),
    status text NOT NULL CHECK (status IN ('PENDING', 'RUNNING', 'COMPLETED', 'PARTIAL', 'FAILED', 'CANCELLED')),
    total_count integer NOT NULL CHECK (total_count BETWEEN 1 AND 100),
    accepted_count integer NOT NULL DEFAULT 0 CHECK (accepted_count >= 0),
    failed_count integer NOT NULL DEFAULT 0 CHECK (failed_count >= 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES smart_alarm.customers(tenant_id, id),
    CHECK (accepted_count + failed_count <= total_count)
);

CREATE TABLE smart_alarm.command_batch_items (
    batch_id uuid NOT NULL REFERENCES smart_alarm.command_batches(id),
    tenant_id uuid NOT NULL REFERENCES smart_alarm.tenants(id),
    device_id uuid NOT NULL,
    operation_id uuid UNIQUE REFERENCES smart_alarm.operations(id),
    status text NOT NULL CHECK (status IN ('PENDING', 'ACCEPTED', 'FAILED', 'CANCELLED')),
    error_code text,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (batch_id, device_id),
    FOREIGN KEY (tenant_id, device_id) REFERENCES smart_alarm.devices(tenant_id, id)
);

CREATE TABLE smart_alarm.notification_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES smart_alarm.tenants(id),
    customer_id uuid,
    source_operation_id uuid REFERENCES smart_alarm.operations(id),
    event_type text NOT NULL CHECK (length(event_type) BETWEEN 1 AND 64),
    severity text NOT NULL CHECK (severity IN ('INFO', 'WARNING', 'CRITICAL')),
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    acknowledgement_status text NOT NULL DEFAULT 'UNACKNOWLEDGED' CHECK (acknowledgement_status IN ('UNACKNOWLEDGED', 'ACKNOWLEDGED')),
    delivery_status text NOT NULL DEFAULT 'PENDING' CHECK (delivery_status IN ('PENDING', 'LEASED', 'DELIVERED', 'DEAD_LETTER')),
    delivery_attempts integer NOT NULL DEFAULT 0 CHECK (delivery_attempts BETWEEN 0 AND 100),
    next_attempt_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    lease_owner text,
    lease_expires_at timestamptz,
    last_error_code text,
    acknowledged_by uuid REFERENCES smart_alarm.users(id),
    acknowledged_at timestamptz,
    delivered_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES smart_alarm.customers(tenant_id, id),
    UNIQUE NULLS NOT DISTINCT (tenant_id, event_type, source_operation_id)
);

CREATE INDEX notification_delivery_idx ON smart_alarm.notification_events (next_attempt_at, id) WHERE delivery_status IN ('PENDING', 'LEASED');

CREATE TABLE smart_alarm.outbox_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid REFERENCES smart_alarm.tenants(id),
    aggregate_type text NOT NULL CHECK (length(aggregate_type) BETWEEN 1 AND 64),
    aggregate_id text NOT NULL CHECK (length(aggregate_id) BETWEEN 1 AND 255),
    event_type text NOT NULL CHECK (length(event_type) BETWEEN 1 AND 128),
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    status text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'LEASED', 'DELIVERED', 'DEAD_LETTER')),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 100),
    next_attempt_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    lease_owner text,
    lease_expires_at timestamptz,
    last_error_code text,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    delivered_at timestamptz
);

CREATE INDEX outbox_claim_idx ON smart_alarm.outbox_events (next_attempt_at, id) WHERE status IN ('PENDING', 'LEASED');

CREATE TABLE smart_alarm.worker_leases (
    lease_key text PRIMARY KEY CHECK (length(lease_key) BETWEEN 1 AND 255),
    owner_id text NOT NULL CHECK (length(owner_id) BETWEEN 1 AND 255),
    fencing_token bigint NOT NULL CHECK (fencing_token > 0),
    expires_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE smart_alarm.collision_events (
    id uuid PRIMARY KEY,
    tenant_id uuid NOT NULL REFERENCES smart_alarm.tenants(id),
    customer_id uuid,
    device_id uuid NOT NULL,
    boot_id text NOT NULL CHECK (length(boot_id) BETWEEN 1 AND 128),
    sequence bigint NOT NULL CHECK (sequence >= 0),
    occurred_at timestamptz NOT NULL,
    recovered_at timestamptz,
    snapshot jsonb NOT NULL CHECK (jsonb_typeof(snapshot) = 'object'),
    content_hash bytea NOT NULL CHECK (octet_length(content_hash) = 32),
    previous_hash bytea CHECK (previous_hash IS NULL OR octet_length(previous_hash) = 32),
    event_hash bytea NOT NULL UNIQUE CHECK (octet_length(event_hash) = 32),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES smart_alarm.customers(tenant_id, id),
    FOREIGN KEY (tenant_id, device_id) REFERENCES smart_alarm.devices(tenant_id, id),
    UNIQUE (tenant_id, device_id, boot_id, sequence)
);

CREATE TABLE smart_alarm.alarm_event_log (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id uuid NOT NULL REFERENCES smart_alarm.tenants(id),
    customer_id uuid,
    thingsboard_alarm_id uuid NOT NULL,
    originator_type text NOT NULL CHECK (originator_type = 'DEVICE'),
    originator_id uuid NOT NULL,
    alarm_type text NOT NULL CHECK (length(alarm_type) BETWEEN 1 AND 128),
    alarm_status text NOT NULL CHECK (length(alarm_status) BETWEEN 1 AND 64),
    platform_ts timestamptz NOT NULL,
    snapshot jsonb NOT NULL CHECK (jsonb_typeof(snapshot) = 'object'),
    content_hash bytea NOT NULL CHECK (octet_length(content_hash) = 32),
    previous_hash bytea CHECK (previous_hash IS NULL OR octet_length(previous_hash) = 32),
    event_hash bytea NOT NULL UNIQUE CHECK (octet_length(event_hash) = 32),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES smart_alarm.customers(tenant_id, id),
    FOREIGN KEY (tenant_id, originator_id) REFERENCES smart_alarm.devices(tenant_id, id),
    UNIQUE (tenant_id, thingsboard_alarm_id, alarm_status, platform_ts)
);

CREATE TABLE smart_alarm.audit_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id uuid REFERENCES smart_alarm.tenants(id),
    customer_id uuid,
    actor_user_id uuid REFERENCES smart_alarm.users(id),
    request_id text NOT NULL CHECK (length(request_id) BETWEEN 8 AND 128),
    action text NOT NULL CHECK (length(action) BETWEEN 1 AND 128),
    resource_type text NOT NULL CHECK (length(resource_type) BETWEEN 1 AND 64),
    resource_id text,
    outcome text NOT NULL CHECK (outcome IN ('ACCEPTED', 'SUCCEEDED', 'REJECTED', 'FAILED', 'OUTCOME_UNKNOWN')),
    detail jsonb NOT NULL CHECK (jsonb_typeof(detail) = 'object'),
    previous_hash bytea CHECK (previous_hash IS NULL OR octet_length(previous_hash) = 32),
    event_hash bytea NOT NULL UNIQUE CHECK (octet_length(event_hash) = 32),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES smart_alarm.customers(tenant_id, id)
);

CREATE INDEX audit_scope_idx ON smart_alarm.audit_events (tenant_id, customer_id, created_at DESC, id DESC);

CREATE FUNCTION smart_alarm.reject_mutation() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION '% is append-only', TG_TABLE_NAME USING ERRCODE = '55000';
END
$$;

CREATE TRIGGER collision_events_append_only
BEFORE UPDATE OR DELETE ON smart_alarm.collision_events
FOR EACH ROW EXECUTE FUNCTION smart_alarm.reject_mutation();

CREATE TRIGGER alarm_event_log_append_only
BEFORE UPDATE OR DELETE ON smart_alarm.alarm_event_log
FOR EACH ROW EXECUTE FUNCTION smart_alarm.reject_mutation();

CREATE TRIGGER audit_events_append_only
BEFORE UPDATE OR DELETE ON smart_alarm.audit_events
FOR EACH ROW EXECUTE FUNCTION smart_alarm.reject_mutation();

ALTER TABLE smart_alarm.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.customers FORCE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.device_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.device_profiles FORCE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.assets FORCE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.business_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.business_groups FORCE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.devices FORCE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.entity_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.entity_groups FORCE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.entity_group_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.entity_group_members FORCE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.entity_relations ENABLE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.entity_relations FORCE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.operations FORCE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.command_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.command_approvals FORCE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.command_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.command_batches FORCE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.command_batch_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.command_batch_items FORCE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.notification_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.notification_events FORCE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.outbox_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.outbox_events FORCE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.collision_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.collision_events FORCE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.alarm_event_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.alarm_event_log FORCE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.audit_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE smart_alarm.audit_events FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_customers ON smart_alarm.customers USING (tenant_id = smart_alarm.current_tenant_id()) WITH CHECK (tenant_id = smart_alarm.current_tenant_id());
CREATE POLICY tenant_isolation_device_profiles ON smart_alarm.device_profiles USING (tenant_id = smart_alarm.current_tenant_id()) WITH CHECK (tenant_id = smart_alarm.current_tenant_id());
CREATE POLICY tenant_isolation_assets ON smart_alarm.assets USING (tenant_id = smart_alarm.current_tenant_id()) WITH CHECK (tenant_id = smart_alarm.current_tenant_id());
CREATE POLICY tenant_isolation_business_groups ON smart_alarm.business_groups USING (tenant_id = smart_alarm.current_tenant_id()) WITH CHECK (tenant_id = smart_alarm.current_tenant_id());
CREATE POLICY tenant_isolation_devices ON smart_alarm.devices USING (tenant_id = smart_alarm.current_tenant_id()) WITH CHECK (tenant_id = smart_alarm.current_tenant_id());
CREATE POLICY tenant_isolation_entity_groups ON smart_alarm.entity_groups USING (tenant_id = smart_alarm.current_tenant_id()) WITH CHECK (tenant_id = smart_alarm.current_tenant_id());
CREATE POLICY tenant_isolation_entity_group_members ON smart_alarm.entity_group_members USING (tenant_id = smart_alarm.current_tenant_id()) WITH CHECK (tenant_id = smart_alarm.current_tenant_id());
CREATE POLICY tenant_isolation_entity_relations ON smart_alarm.entity_relations USING (tenant_id = smart_alarm.current_tenant_id()) WITH CHECK (tenant_id = smart_alarm.current_tenant_id());
CREATE POLICY tenant_isolation_operations ON smart_alarm.operations USING (tenant_id = smart_alarm.current_tenant_id()) WITH CHECK (tenant_id = smart_alarm.current_tenant_id());
CREATE POLICY tenant_isolation_command_approvals ON smart_alarm.command_approvals USING (tenant_id = smart_alarm.current_tenant_id()) WITH CHECK (tenant_id = smart_alarm.current_tenant_id());
CREATE POLICY tenant_isolation_command_batches ON smart_alarm.command_batches USING (tenant_id = smart_alarm.current_tenant_id()) WITH CHECK (tenant_id = smart_alarm.current_tenant_id());
CREATE POLICY tenant_isolation_command_batch_items ON smart_alarm.command_batch_items USING (tenant_id = smart_alarm.current_tenant_id()) WITH CHECK (tenant_id = smart_alarm.current_tenant_id());
CREATE POLICY tenant_isolation_notification_events ON smart_alarm.notification_events USING (tenant_id = smart_alarm.current_tenant_id()) WITH CHECK (tenant_id = smart_alarm.current_tenant_id());
CREATE POLICY tenant_isolation_outbox_events ON smart_alarm.outbox_events USING (tenant_id = smart_alarm.current_tenant_id()) WITH CHECK (tenant_id = smart_alarm.current_tenant_id());
CREATE POLICY tenant_isolation_collision_events ON smart_alarm.collision_events USING (tenant_id = smart_alarm.current_tenant_id()) WITH CHECK (tenant_id = smart_alarm.current_tenant_id());
CREATE POLICY tenant_isolation_alarm_event_log ON smart_alarm.alarm_event_log USING (tenant_id = smart_alarm.current_tenant_id()) WITH CHECK (tenant_id = smart_alarm.current_tenant_id());
CREATE POLICY tenant_isolation_audit_events ON smart_alarm.audit_events USING (tenant_id = smart_alarm.current_tenant_id()) WITH CHECK (tenant_id = smart_alarm.current_tenant_id());

COMMENT ON SCHEMA smart_alarm IS 'Smart Alarm product control-plane data; never shared with ThingsBoard internal tables';
COMMENT ON COLUMN smart_alarm.devices.credential_secret_ref IS 'Vault/KMS reference only; plaintext device credentials are forbidden';
COMMENT ON TABLE smart_alarm.outbox_events IS 'Transactional external side effects claimed with FOR UPDATE SKIP LOCKED';
COMMENT ON TABLE smart_alarm.audit_events IS 'Append-only hash chained audit association log';
