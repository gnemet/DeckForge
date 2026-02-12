-- migration: 011_seed_bdo_fdd
-- Initialize BDO tenant and FDD theme
-- 1. Insert BDO Tenant
-- Using a stable name, UUID will be generated
INSERT INTO tenants (name)
VALUES ('BDO') ON CONFLICT DO NOTHING;
-- 2. Insert FDD Theme for BDO
-- We need to look up the ID just in case
DO $$
DECLARE v_tenant_id UUID;
BEGIN
SELECT id INTO v_tenant_id
FROM tenants
WHERE name = 'BDO';
IF v_tenant_id IS NOT NULL THEN
INSERT INTO themes (tenant_id, name, description)
VALUES (
        v_tenant_id,
        'FDD',
        'Financial Due Diligence Theme'
    ) ON CONFLICT (tenant_id, name) DO NOTHING;
END IF;
END $$;