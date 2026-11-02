--
-- Name: claude_session; Type: TABLE; Schema: @SCHEMA@; Owner: -
-- OPTIONAL presence tracking (ClaudeDock presence prop): one row per user per visit. A visit ends when its
-- user sends no heartbeat for 5 minutes; the next heartbeat opens a new row.
--

CREATE TABLE IF NOT EXISTS @SCHEMA@.claude_session (
    id bigserial PRIMARY KEY,
    who text NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    page_loads integer DEFAULT 0 NOT NULL,
    views integer DEFAULT 0 NOT NULL,
    urls jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_url text,
    messages integer DEFAULT 0 NOT NULL,
    user_agent text
);
CREATE INDEX IF NOT EXISTS claude_session_who ON @SCHEMA@.claude_session (who, last_seen_at DESC);
COMMENT ON TABLE @SCHEMA@.claude_session IS 'optional presence tracking: per-user visits (start/end, page loads, url views, messages sent to claude-ui)';
COMMENT ON COLUMN @SCHEMA@.claude_session.who IS 'the JWT''s name claim, else email, else sub (same as claude_msg.sender)';
COMMENT ON COLUMN @SCHEMA@.claude_session.urls IS '{url path: views} during this visit';
