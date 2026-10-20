-- Name: claude_img; Type: TABLE; Schema: @SCHEMA@; Owner: -
--

CREATE TABLE @SCHEMA@.claude_img (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    ts timestamp with time zone DEFAULT now() NOT NULL,
    mime text NOT NULL,
    caption text,
    bytes bytea NOT NULL,
    sha256 text,
    CONSTRAINT claude_img_mime_check CHECK ((mime = ANY (ARRAY['image/png'::text, 'image/jpeg'::text, 'image/gif'::text, 'image/webp'::text])))
);


--
