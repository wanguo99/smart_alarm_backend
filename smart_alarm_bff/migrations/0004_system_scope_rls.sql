CREATE FUNCTION smart_alarm.is_system_scope() RETURNS boolean
LANGUAGE sql STABLE PARALLEL SAFE
AS $$
    SELECT current_setting('smart_alarm.system_scope', true) = 'true'
$$;

DO $$
DECLARE
    table_name text;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'customers', 'device_profiles', 'assets', 'business_groups', 'devices',
        'entity_groups', 'entity_group_members', 'entity_relations', 'operations',
        'command_approvals', 'command_batches', 'command_batch_items',
        'notification_events', 'outbox_events', 'collision_events',
        'alarm_event_log', 'audit_events'
    ] LOOP
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation_%I ON smart_alarm.%I', table_name, table_name);
        EXECUTE format(
            'CREATE POLICY tenant_isolation_%I ON smart_alarm.%I USING (smart_alarm.is_system_scope() OR tenant_id = smart_alarm.current_tenant_id()) WITH CHECK (smart_alarm.is_system_scope() OR tenant_id = smart_alarm.current_tenant_id())',
            table_name, table_name
        );
    END LOOP;
END
$$;
