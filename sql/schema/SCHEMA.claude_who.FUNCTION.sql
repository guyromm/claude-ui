--
-- Name: claude_who(); Type: FUNCTION; Schema: @SCHEMA@; Owner: -
-- who is calling: the same name api.claude_send stores in claude_msg.author (@WHO@, CLAUDE_UI_WHO_FN); claude_session.who
--

CREATE OR REPLACE FUNCTION @SCHEMA@.claude_who() RETURNS text
    LANGUAGE sql STABLE
    AS $$ SELECT nullif(@WHO@, '') $$;
