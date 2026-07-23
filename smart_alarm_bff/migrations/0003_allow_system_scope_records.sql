DROP POLICY tenant_isolation_operations ON smart_alarm.operations;
CREATE POLICY tenant_isolation_operations ON smart_alarm.operations
    USING (tenant_id = smart_alarm.current_tenant_id() OR (tenant_id IS NULL AND smart_alarm.current_tenant_id() IS NULL))
    WITH CHECK (tenant_id = smart_alarm.current_tenant_id() OR (tenant_id IS NULL AND smart_alarm.current_tenant_id() IS NULL));

DROP POLICY tenant_isolation_outbox_events ON smart_alarm.outbox_events;
CREATE POLICY tenant_isolation_outbox_events ON smart_alarm.outbox_events
    USING (tenant_id = smart_alarm.current_tenant_id() OR (tenant_id IS NULL AND smart_alarm.current_tenant_id() IS NULL))
    WITH CHECK (tenant_id = smart_alarm.current_tenant_id() OR (tenant_id IS NULL AND smart_alarm.current_tenant_id() IS NULL));

DROP POLICY tenant_isolation_audit_events ON smart_alarm.audit_events;
CREATE POLICY tenant_isolation_audit_events ON smart_alarm.audit_events
    USING (tenant_id = smart_alarm.current_tenant_id() OR (tenant_id IS NULL AND smart_alarm.current_tenant_id() IS NULL))
    WITH CHECK (tenant_id = smart_alarm.current_tenant_id() OR (tenant_id IS NULL AND smart_alarm.current_tenant_id() IS NULL));
