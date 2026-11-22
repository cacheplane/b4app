-- Capability support is deployed before the owner raises this admission floor.
INSERT INTO public.hub_settings (key, value) VALUES ('client_protocol', '{"minClientProtocol":1}'::jsonb);

-- Only public profile/retirement metadata is mirrored. Authentication stays on the Mac.
ALTER TABLE public.connections
    ADD COLUMN "peerProfile" text,
    ADD COLUMN "agentId" text,
    ADD COLUMN "protocolRetiredAt" text,
    ADD COLUMN "protocolRetiredReason" text;
