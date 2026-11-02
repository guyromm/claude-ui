--
-- Name: claude_session_touch(text, boolean, integer); Type: FUNCTION; Schema: @SCHEMA@; Owner: -
-- the caller's current visit (opened if the last one is older than 5 minutes), counters bumped
--

CREATE OR REPLACE FUNCTION @SCHEMA@.claude_session_touch(p_url text, p_load boolean, p_msgs integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
  DECLARE w text := @SCHEMA@.claude_who(); sid bigint; u text := left(nullif(p_url, ''), 300);
  BEGIN
    IF w IS NULL THEN RETURN; END IF;
    SELECT id INTO sid FROM @SCHEMA@.claude_session
     WHERE who = w AND last_seen_at > now() - interval '5 minutes' ORDER BY last_seen_at DESC LIMIT 1 FOR UPDATE;
    IF sid IS NULL THEN
      INSERT INTO @SCHEMA@.claude_session(who, user_agent)
      VALUES (w, left(coalesce(nullif(current_setting('request.headers', true), ''), '{}')::jsonb->>'user-agent', 300))
      RETURNING id INTO sid;
    END IF;
    UPDATE @SCHEMA@.claude_session SET
      last_seen_at = now(),
      page_loads = page_loads + CASE WHEN p_load THEN 1 ELSE 0 END,
      views = views + CASE WHEN u IS NOT NULL AND (p_load OR u IS DISTINCT FROM last_url) THEN 1 ELSE 0 END,
      urls = CASE WHEN u IS NOT NULL AND (p_load OR u IS DISTINCT FROM last_url)
                  THEN urls || jsonb_build_object(u, coalesce((urls->>u)::int, 0) + 1) ELSE urls END,
      last_url = coalesce(u, last_url),
      messages = messages + coalesce(p_msgs, 0)
    WHERE id = sid;
  END $$;
