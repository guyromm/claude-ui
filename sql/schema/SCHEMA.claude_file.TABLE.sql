-- Name: claude_file; Type: TABLE; Schema: @SCHEMA@; Owner: -
--

CREATE TABLE @SCHEMA@.claude_file (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    ts timestamp with time zone DEFAULT now() NOT NULL,
    name text NOT NULL,
    mime text NOT NULL,
    bytes bytea DEFAULT '\x'::bytea NOT NULL,
    path text
);


--
