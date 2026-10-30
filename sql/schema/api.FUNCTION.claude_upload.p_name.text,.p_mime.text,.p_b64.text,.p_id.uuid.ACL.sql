-- Name: FUNCTION claude_upload(p_name text, p_mime text, p_b64 text, p_id uuid); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.claude_upload(p_name text, p_mime text, p_b64 text, p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION api.claude_upload(p_name text, p_mime text, p_b64 text, p_id uuid) TO @ANON_ROLE@;
GRANT ALL ON FUNCTION api.claude_upload(p_name text, p_mime text, p_b64 text, p_id uuid) TO @AUTH_ROLE@;


--
