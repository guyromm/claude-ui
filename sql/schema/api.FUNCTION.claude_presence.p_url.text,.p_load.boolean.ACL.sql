--
-- Name: FUNCTION claude_presence(p_url text, p_load boolean); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.claude_presence(p_url text, p_load boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION api.claude_presence(p_url text, p_load boolean) TO @AUTH_ROLE@;
