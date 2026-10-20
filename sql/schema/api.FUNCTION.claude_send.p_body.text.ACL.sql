-- Name: FUNCTION claude_send(p_body text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.claude_send(p_body text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.claude_send(p_body text) TO @ANON_ROLE@;
GRANT ALL ON FUNCTION api.claude_send(p_body text) TO @AUTH_ROLE@;


--
