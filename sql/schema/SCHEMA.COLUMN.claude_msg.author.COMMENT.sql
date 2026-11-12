-- Name: COLUMN claude_msg.author; Type: COMMENT; Schema: @SCHEMA@; Owner: -
--

COMMENT ON COLUMN @SCHEMA@.claude_msg.author IS 'who sent an in row from the page (CLAUDE_UI_WHO_FN over the JWT claims, set by api.claude_send); the relay types it as a "[from <author>]" prefix so the session knows which admin is talking, only on multi-admin hosts (CLAUDE_UI_AUTHOR_PREFIX=auto|always|never; auto = more than one distinct author seen). NULL for transcript mirrors and old rows';


--
