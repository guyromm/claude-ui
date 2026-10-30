-- Name: claude_upload(text, text, text, uuid); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.claude_upload(p_name text, p_mime text, p_b64 text, p_id uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
  -- CHUNKED: the host's proxy caps a request body (a few MB on this stack), a phone photo or a PDF can be
  -- bigger. The first call (p_id NULL) creates the row, each later one appends to it; 50 MB per file.
  DECLARE new_id uuid;
  BEGIN
    IF NOT @ADMIN@ THEN RAISE EXCEPTION 'admin only'; END IF;
    IF p_id IS NULL THEN
      IF p_name IS NULL OR length(trim(p_name)) = 0 THEN RAISE EXCEPTION 'name required'; END IF;
      INSERT INTO @SCHEMA@.claude_file(name, mime, bytes)
        VALUES (left(trim(p_name), 200), coalesce(nullif(p_mime, ''), 'application/octet-stream'), decode(p_b64, 'base64'))
        RETURNING id INTO new_id;
      RETURN new_id;
    END IF;
    UPDATE @SCHEMA@.claude_file SET bytes = bytes || decode(p_b64, 'base64')
     WHERE id = p_id AND path IS NULL AND ts > now() - interval '1 hour'
       AND length(bytes) + length(p_b64) * 3 / 4 <= 50 * 1024 * 1024
    RETURNING id INTO new_id;
    IF new_id IS NULL THEN RAISE EXCEPTION 'upload % is sealed, expired, or over 50 MB', p_id; END IF;
    RETURN new_id;
  END $$;


--
