-- Name: COLUMN claude_msg.fail_reason; Type: COMMENT; Schema: @SCHEMA@; Owner: -
--

COMMENT ON COLUMN @SCHEMA@.claude_msg.fail_reason IS 'set by the relay IN loop when send-keys to the pane failed for THIS row (e.g. tmux command too long); such a row is parked -- excluded from delivery -- until the reason is cleared';


--
