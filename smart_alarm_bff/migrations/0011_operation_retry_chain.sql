CREATE UNIQUE INDEX operations_single_retry_child_uq
    ON smart_alarm.operations (parent_operation_id)
    WHERE parent_operation_id IS NOT NULL;

COMMENT ON INDEX smart_alarm.operations_single_retry_child_uq IS
    'A failed operation has at most one explicit retry child, preventing concurrent retry forks';
