ALTER TABLE smart_alarm.device_profiles
    ADD COLUMN profile_type text NOT NULL DEFAULT 'DEFAULT' CHECK (length(profile_type) BETWEEN 1 AND 64),
    ADD COLUMN transport_type text NOT NULL DEFAULT 'MQTT' CHECK (transport_type IN ('MQTT', 'HTTP', 'COAP', 'LWM2M', 'SNMP'));
