;;;; yaml.scm
;;;; Bindings to libyaml

(module yaml
  (yaml-parse yaml-load)

(import scheme chicken foreign irregex)
(use irregex srfi-13 lolevel)

(foreign-declare "#include <yaml.h>")


(define (sequence-end seed)
  (let loop ((the-list '()) (stack seed))
    (if (eq? 'sequence-start (car stack))
      (cons the-list (cdr stack))
      (loop (cons (car stack) the-list) (cdr stack)))))

(define (mapping-end seed)
  (let loop ((the-list '()) (stack seed))
    (if (eq? 'mapping-start (car stack))
        (cons the-list (cdr stack))
        (loop (cons (cons (cadr stack) (car stack)) the-list) (cddr stack)))))

(define (scalar value anchor tag plain quoted style seed)
  (cons (parse-scalar value) seed))

(define (parse-scalar value)
  (cond ((irregex-match "[-+]?[0-9]+" value) (string->number value))
        ((irregex-match "[-+]?([0-9][0-9_,]*)?\.[0-9]*([eE][-+][0-9]+)?|[+-]?" value)
         (string->number (irregex-replace/all "[,_]" value "")))
        ((irregex-match "[-+]?.(?:inf|INF|Inf)" value)
         (string->number (irregex-replace/all "[.]" value "")))
        ((irregex-match "[-+]?.(?:nan|NaN|NAN)" value)
         (string->number (irregex-replace/all "[.]" value "")))
        (else value)))

(define (yaml-load yaml)
  (yaml-parse yaml
              (lambda (enc seed) (cons 'stream-start seed))
              (lambda (seed) seed)
              (lambda (version tags seed)
                      (cons 'document-start seed))
              (lambda (implicit? seed) (car seed))
              (lambda (alias seed) seed)
              scalar
              (lambda (anchor tag implicit style seed)
                      (cons 'sequence-start seed))
              sequence-end
              (lambda (anchor tag implicit style seed)
                      (cons 'mapping-start seed))
              mapping-end
              '()))

(define-foreign-type yaml_parser (c-pointer "yaml_parser_t"))
(define-foreign-type yaml_parser_t (c-pointer "yaml_parser_t"))
(define-foreign-type yaml_event_t (c-pointer "yaml_event_t"))
(define-foreign-type yaml_tag_directive_t (c-pointer "yaml_tag_directive_t"))
(define sizeof_tag_directive_t (foreign-type-size "yaml_tag_directive_t"))
(define sizeof_parser_t (foreign-type-size "yaml_parser_t"))

(define (add-tag pair tags) (append tags (list pair)))

(define-record-type parser-context
                    (wrap-parser context
                                 stream-start
                                 stream-end
                                 document-start
                                 document-end
                                 alias
                                 scalar
                                 sequence-start
                                 sequence-end
                                 mapping-start
                                 mapping-end
                                 seed)
                    parser-context?
                    (context get-context)
                    (stream-start get-stream-start)
                    (stream-end get-stream-end)
                    (document-start get-document-start)
                    (document-end get-document-end)
                    (sequence-start get-sequence-start)
                    (sequence-end get-sequence-end)
                    (mapping-start get-mapping-start)
                    (mapping-end get-mapping-end)
                    (scalar get-scalar)
                    (alias get-alias)
                    (seed get-seed))

(define (yaml-parse yaml
                    stream-start
                    stream-end
                    document-start
                    document-end
                    alias
                    scalar
                    sequence-start
                    sequence-end
                    mapping-start
                    mapping-end
                    seed)
  (let* ((parser (make-yaml-parser))
         (ctx (wrap-parser parser
                           stream-start
                           stream-end
                           document-start
                           document-end
                           alias
                           scalar
                           sequence-start
                           sequence-end
                           mapping-start
                           mapping-end
                           seed)))
    (do-parse yaml ctx)))

(define yaml:stream-start-event (foreign-value "YAML_STREAM_START_EVENT" int))
(define yaml:stream-end-event (foreign-value "YAML_STREAM_END_EVENT" int))
(define yaml:document-start-event (foreign-value "YAML_DOCUMENT_START_EVENT" int))
(define yaml:document-end-event (foreign-value "YAML_DOCUMENT_END_EVENT" int))
(define yaml:alias-event (foreign-value "YAML_ALIAS_EVENT" int))
(define yaml:scalar-event (foreign-value "YAML_SCALAR_EVENT" int))
(define yaml:sequence-start-event (foreign-value "YAML_SEQUENCE_START_EVENT" int))
(define yaml:sequence-end-event (foreign-value "YAML_SEQUENCE_END_EVENT" int))
(define yaml:mapping-start-event (foreign-value "YAML_MAPPING_START_EVENT" int))
(define yaml:mapping-end-event (foreign-value "YAML_MAPPING_END_EVENT" int))

(define (handle-stream-start-event ctx event seed)
  (let ((cb (get-stream-start ctx)))
    (cb (event.data.start_stream.encoding event) seed)))

(define (handle-stream-end-event ctx event seed)
  ((get-stream-end ctx) seed))

(define (handle-document-start-event ctx event seed)
  (let ((cb (get-document-start ctx)))
    (cb (document-version-directives event)
        (tag-directives event)
        seed)))

(define (handle-document-end-event ctx event seed)
  (let ((cb (get-document-end ctx)))
    (cb (if (= 0 (document-end-implicit event)) #f #t)
        seed)))

(define (handle-sequence-start-event ctx event seed)
  (let ((cb (get-sequence-start ctx)))
    (cb (sequence-anchor event)
        (sequence-tag event)
        (if (= 0 (sequence-implicit event)) #f #t)
        (sequence-style event)
        seed)))

(define (handle-mapping-start-event ctx event seed)
  (let ((cb (get-mapping-start ctx)))
    (cb (mapping-anchor event)
        (mapping-tag event)
        (if (= 0 (mapping-implicit event)) #f #t)
        (mapping-style event)
        seed)))

(define (handle-sequence-end-event ctx event seed)
  ((get-sequence-end ctx) seed))

(define (handle-scalar-event ctx event seed)
  (let ((cb (get-scalar ctx)))
    (cb (scalar-value event)
        (scalar-anchor event)
        (scalar-tag event)
        (if (= 0 (scalar-plain-implicit event)) #f #t)
        (if (= 0 (scalar-quoted-implicit event)) #f #t)
        (scalar-style event)
        seed)))

(define (handle-alias-event ctx event seed)
  ((get-alias ctx) (alias-anchor event) seed))

(define (handle-mapping-end-event ctx event seed)
  ((get-mapping-end ctx) seed))

(define (pull-event parser event)
  (let ((state (yaml_parser_parse parser event)))
    (if (= 0 state)
        (begin
          (yaml_parser_delete parser)
          (free event)
          (error "something is broken"))
        state)))

(define (parse-loop ctx parser event seed)
  (let* ((state (pull-event parser event))
         (type (event.type event)))
    (cond ((= yaml:stream-start-event type)
           (parse-loop ctx parser event
                       (handle-stream-start-event ctx event seed)))

          ((= yaml:document-start-event type)
           (parse-loop ctx parser event
                       (handle-document-start-event ctx event seed)))

          ((= yaml:sequence-start-event type)
           (parse-loop ctx parser event
                       (handle-sequence-start-event ctx event seed)))

          ((= yaml:sequence-end-event type)
           (parse-loop ctx parser event
                       (handle-sequence-end-event ctx event seed)))

          ((= yaml:mapping-start-event type)
           (parse-loop ctx parser event
                       (handle-mapping-start-event ctx event seed)))

          ((= yaml:mapping-end-event type)
           (parse-loop ctx parser event
                       (handle-mapping-end-event ctx event seed)))

          ((= yaml:scalar-event type)
           (parse-loop ctx parser event
                       (handle-scalar-event ctx event seed)))

          ((= yaml:alias-event type)
           (parse-loop ctx parser event
                       (handle-alias-event ctx event seed)))

          ((= yaml:document-end-event type)
           (parse-loop ctx parser event
                       (handle-document-end-event ctx event seed)))

          ((= yaml:stream-end-event type)
           (handle-stream-end-event ctx event seed))

          (else (parse-loop ctx parser event seed)))))

(define (do-parse yaml ctx)
  (yaml_parser_set_input_string (get-context ctx)
                                yaml
                                (string-length yaml))
  (let ((parser (get-context ctx))
        (event (make-yaml-event)))
    (let ((seed (parse-loop ctx parser event (get-seed ctx))))
      (free event)
      seed)))


(define yaml_parser_set_input_string (foreign-lambda void
                                                     "yaml_parser_set_input_string"
                                                     yaml_parser_t
                                                     nonnull-unsigned-c-string
                                                     size_t))
(define (make-yaml-parser)
  (set-finalizer! (alloc-yaml-parser) free-yaml-parser!))

(define (make-yaml-event) (allocate (foreign-type-size "yaml_event_t")))

(define yaml_event_delete (foreign-lambda void
                                          "yaml_event_delete"
                                          yaml_event_t))

(define yaml_parser_parse (foreign-lambda int
                                          "yaml_parser_parse"
                                          yaml_parser_t
                                          yaml_event_t))

(define yaml_parser_initialize (foreign-lambda int
                                               "yaml_parser_initialize"
                                               yaml_parser_t))

(define (alloc-yaml-parser)
  (let ((parser (allocate sizeof_parser_t)))
    (yaml_parser_initialize parser)
    parser))

(define (free-yaml-parser! parser)
  (yaml_parser_delete parser)
  (free parser))

(define event.data.start_stream.encoding (foreign-lambda* int
  ((yaml_event_t event))
  "C_return(event->data.stream_start.encoding);"))

(define event.data.document_start.version_directive (foreign-lambda* c-pointer
  ((yaml_event_t event))
  "C_return(event->data.document_start.version_directive);"))

(define event.data.document_start.version_directive->major (foreign-lambda* int
  ((yaml_event_t event))
  "C_return(event->data.document_start.version_directive->major);"))

(define event.data.document_start.version_directive->minor (foreign-lambda* int
  ((yaml_event_t event))
  "C_return(event->data.document_start.version_directive->minor);"))

(define (document-version-directives event)
  (if (event.data.document_start.version_directive event)
      (list (event.data.document_start.version_directive->major event)
            (event.data.document_start.version_directive->minor event))
      '()))

(define tag-directives.start (foreign-lambda*
  yaml_tag_directive_t
  ((yaml_event_t event))
  "C_return(event->data.document_start.tag_directives.start);"))

(define tag-directives.end (foreign-lambda*
  yaml_tag_directive_t
  ((yaml_event_t event))
  "C_return(event->data.document_start.tag_directives.end);"))

(define tag-handle (foreign-lambda* c-string
                                    ((yaml_tag_directive_t tag))
                                    "C_return(tag->handle);"))

(define tag-prefix (foreign-lambda* c-string
                                    ((yaml_tag_directive_t tag))
                                    "C_return(tag->prefix);"))
(define (tag-info tag)
  (cons (tag-handle tag) (tag-prefix tag)))

(define (tag-directives event)
  (let loop ((start (tag-directives.start event))
            (end (tag-directives.end event))
            (acc '()))
    (if (or (not start) (pointer=? start end))
        acc
        (loop (pointer+ start sizeof_tag_directive_t) end (cons (tag-info start) acc)))))

(define (scalar-value event)
  (let* ((len (scalar-len event))
         (str (make-string len)))
    (move-memory! (scalar-ptr event) str len)
    str))

(define scalar-len (foreign-lambda* int
                                    ((yaml_event_t event))
                                    "C_return(event->data.scalar.length);"))

(define scalar-ptr (foreign-lambda* c-pointer
                                    ((yaml_event_t event))
                                    "C_return(event->data.scalar.value);"))

(define scalar-anchor (foreign-lambda* c-string
                                       ((yaml_event_t e))
                                       "C_return(e->data.scalar.anchor);"))

(define scalar-tag (foreign-lambda* c-string
                                       ((yaml_event_t e))
                                       "C_return(e->data.scalar.tag);"))

(define scalar-plain-implicit (foreign-lambda* int
                                       ((yaml_event_t e))
                                       "C_return(e->data.scalar.plain_implicit);"))

(define scalar-quoted-implicit (foreign-lambda* int
                                       ((yaml_event_t e))
                                       "C_return(e->data.scalar.quoted_implicit);"))

(define scalar-style (foreign-lambda* int
                                       ((yaml_event_t e))
                                       "C_return(e->data.scalar.style);"))

(define document-end-implicit (foreign-lambda* int
                                       ((yaml_event_t e))
                                       "C_return(e->data.document_end.implicit);"))

(define sequence-anchor (foreign-lambda* c-string
                                       ((yaml_event_t e))
                                       "C_return(e->data.sequence_start.anchor);"))

(define sequence-tag (foreign-lambda* c-string
                                       ((yaml_event_t e))
                                       "C_return(e->data.sequence_start.tag);"))

(define sequence-implicit (foreign-lambda* int
                                       ((yaml_event_t e))
                                       "C_return(e->data.sequence_start.implicit);"))

(define sequence-style (foreign-lambda* int
                                       ((yaml_event_t e))
                                       "C_return(e->data.sequence_start.style);"))

(define mapping-anchor (foreign-lambda* c-string
                                       ((yaml_event_t e))
                                       "C_return(e->data.mapping_start.anchor);"))

(define mapping-tag (foreign-lambda* c-string
                                       ((yaml_event_t e))
                                       "C_return(e->data.mapping_start.tag);"))

(define mapping-implicit (foreign-lambda* int
                                       ((yaml_event_t e))
                                       "C_return(e->data.mapping_start.implicit);"))

(define mapping-style (foreign-lambda* int
                                       ((yaml_event_t e))
                                       "C_return(e->data.mapping_start.style);"))

(define alias-anchor (foreign-lambda* c-string
                                       ((yaml_event_t e))
                                       "C_return(e->data.alias.anchor);"))

(define yaml_parser_delete (foreign-lambda void
                                           "yaml_parser_delete"
                                            yaml_parser_t))

(define event.type (foreign-lambda* int
  ((yaml_event_t event))
  "C_return(event->type);"))
)
