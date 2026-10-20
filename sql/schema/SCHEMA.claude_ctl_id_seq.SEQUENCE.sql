-- Name: claude_ctl_id_seq; Type: SEQUENCE; Schema: @SCHEMA@; Owner: -
--

ALTER TABLE @SCHEMA@.claude_ctl ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME @SCHEMA@.claude_ctl_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
