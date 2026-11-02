-- Run once per account, from the `psql` container of the hub-admin task
-- (Infra/scripts/admin-shell.sh <env> psql), connected as the RDS master user.
--
-- The password is a psql variable, never a literal: pass it on standard input
-- or with \set at the prompt, so it lands in neither the shell history nor a
-- file (see the "Bootstrap the database owner" runbook in Infra/README.md).
--
-- b4hub_owner becomes DATABASE_ADMIN_URL's user. It owns every table
-- `b4hub migrate` creates, and CREATEROLE is all migrate needs to create and
-- grant b4hub_app later. The master user is used nowhere else.
CREATE ROLE b4hub_owner WITH LOGIN CREATEROLE PASSWORD :'owner_password';
-- PostgreSQL 16+ (createrole_self_grant is empty by default) gives the creator
-- only ADMIN OPTION on a new role, and CREATE DATABASE ... OWNER needs SET ROLE.
GRANT b4hub_owner TO CURRENT_USER;
CREATE DATABASE b4hub OWNER b4hub_owner;
