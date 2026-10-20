-- Name: claude_msg; Type: TABLE; Schema: @SCHEMA@; Owner: -
--

CREATE TABLE @SCHEMA@.claude_msg (
    id bigint NOT NULL,
    ts timestamp with time zone DEFAULT now() NOT NULL,
    direction text NOT NULL,
    body text NOT NULL,
    delivered boolean DEFAULT false NOT NULL,
    src_uuid text,
    suggest text,
    fail_reason text,
    CONSTRAINT claude_msg_direction_check CHECK ((direction = ANY (ARRAY['in'::text, 'out'::text, 'sys'::text])))
);


--
