-- Name: TABLE claude_msg; Type: COMMENT; Schema: @SCHEMA@; Owner: -
--

COMMENT ON TABLE @SCHEMA@.claude_msg IS 'Phone<->Claude voice bridge. out=assistant (from transcript tail), in=phone STT (relayed to the claude pane via tmux send-keys). Admin-only.';


--
