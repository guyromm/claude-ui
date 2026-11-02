--
-- Name: claude_sessions; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.claude_sessions AS
 SELECT id, who, started_at, last_seen_at AS ended_at,
    (last_seen_at - started_at) AS duration,
    (last_seen_at > (now() - '00:01:00'::interval)) AS online,
    page_loads, views, urls, messages, user_agent
   FROM @SCHEMA@.claude_session
  WHERE @ADMIN@;
