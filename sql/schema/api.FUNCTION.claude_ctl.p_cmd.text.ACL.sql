-- Name: FUNCTION claude_ctl(p_cmd text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.claude_ctl(p_cmd text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.claude_ctl(p_cmd text) TO @ANON_ROLE@;
GRANT ALL ON FUNCTION api.claude_ctl(p_cmd text) TO @AUTH_ROLE@;


--
