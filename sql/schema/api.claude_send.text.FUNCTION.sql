-- Name: claude_send(text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.claude_send(p_body text) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
  DECLARE new_id bigint;
  BEGIN
    IF NOT @ADMIN@ THEN RAISE EXCEPTION 'admin only'; END IF;
    IF p_body IS NULL OR length(trim(p_body)) = 0 THEN RAISE EXCEPTION 'empty'; END IF;
    INSERT INTO @SCHEMA@.claude_msg(direction, body) VALUES('in', trim(p_body)) RETURNING id INTO new_id;
    RETURN new_id;
  END $$;


--
