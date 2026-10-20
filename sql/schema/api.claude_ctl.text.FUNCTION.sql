-- Name: claude_ctl(text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.claude_ctl(p_cmd text) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
  DECLARE new_id bigint;
  BEGIN
    IF NOT @ADMIN@ THEN RAISE EXCEPTION 'admin only'; END IF;
    IF p_cmd NOT IN ('int','int2') THEN RAISE EXCEPTION 'bad cmd'; END IF;
    INSERT INTO @SCHEMA@.claude_ctl(cmd) VALUES(p_cmd) RETURNING id INTO new_id;
    RETURN new_id;
  END $$;


--
