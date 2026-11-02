--
-- Name: claude_presence(text, boolean); Type: FUNCTION; Schema: api; Owner: -
-- heartbeat from ClaudeDock (presence prop): every 30 s, on page load (p_load) and on navigation
--

CREATE OR REPLACE FUNCTION api.claude_presence(p_url text DEFAULT NULL, p_load boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
  BEGIN
    IF NOT @ADMIN@ THEN RETURN; END IF;
    PERFORM @SCHEMA@.claude_session_touch(p_url, p_load, 0);
  END $$;
