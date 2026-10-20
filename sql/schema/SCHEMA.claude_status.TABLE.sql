-- Name: claude_status; Type: TABLE; Schema: @SCHEMA@; Owner: -
--

CREATE TABLE @SCHEMA@.claude_status (
    singleton boolean DEFAULT true NOT NULL,
    state text NOT NULL,
    detail text,
    since timestamp with time zone NOT NULL,
    ts timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT claude_status_singleton_check CHECK (singleton),
    CONSTRAINT claude_status_state_check CHECK ((state = ANY (ARRAY['working'::text, 'waiting'::text])))
);


--
