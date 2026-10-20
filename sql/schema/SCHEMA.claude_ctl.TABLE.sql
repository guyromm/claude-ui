-- Name: claude_ctl; Type: TABLE; Schema: @SCHEMA@; Owner: -
--

CREATE TABLE @SCHEMA@.claude_ctl (
    id bigint NOT NULL,
    ts timestamp with time zone DEFAULT now() NOT NULL,
    cmd text NOT NULL,
    delivered boolean DEFAULT false NOT NULL,
    CONSTRAINT claude_ctl_cmd_check CHECK ((cmd = ANY (ARRAY['int'::text, 'int2'::text])))
);


--
