/*
 * ngx_http_isonim_module.c
 *
 * nginx HTTP module for IsoNim server-side rendering.
 *
 * This C file is the entry point that nginx loads as a dynamic shared
 * object.  It defines:
 *
 *   - the per-location configuration (the isonim_ssr* and isonim_rpc*
 *     directives);
 *   - the content handler, which hands the request to Nim: at once for an
 *     SSR location, after reading the request body asynchronously
 *     (ngx_http_read_client_request_body) for an isonim_rpc location;
 *   - the per-request state of an isonim_rpc request: its timeout timer and
 *     the pool cleanup that tells Nim the request is gone;
 *   - a request body filter that enforces isonim_rpc_max_body_size while
 *     the body is read (a body without Content-Length is refused as soon as
 *     the running total exceeds it, so nothing larger is ever buffered);
 *   - the hookup of Nim's event loop (std/asyncdispatch) to the worker's:
 *     the dispatcher's epoll descriptor as a level-triggered read event,
 *     and one timer for its next due timer (async_loop.nim);
 *   - a small set of helpers that Nim calls back into to send the response
 *     (status and headers, body buffers, finalization, error log lines).
 *     They live here because they touch nginx structures (headers_out,
 *     ngx_buf_t bitfields, the connection log) that are clearer to
 *     manipulate from C.
 *
 * Request handling itself (method check, app lookup, rendering, response
 * shaping, the hydration script and its per-response CSP nonce, the
 * isonim_ssr_max_buffer_size limit, and the streaming or buffered transport)
 * lives in serve.nim and is shared with the mock-mode unit tests; the
 * isonim_rpc pipeline (server-function dispatch or an async app, the
 * response, the timeout) lives in rpc.nim.
 */

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>

/* ------------------------------------------------------------------ */
/* The request view handed to Nim.                                    */
/*                                                                    */
/* Mirrored by RequestView in handler.nim.  Nim checks the size we    */
/* pass against its own sizeof(RequestView), so a layout drift fails  */
/* the request with a logged error instead of reading garbage.        */
/* ------------------------------------------------------------------ */

typedef struct {
    ngx_str_t         method;        /* r->method_name                     */
    ngx_str_t         uri;           /* r->uri: decoded, normalized path   */
    ngx_str_t         args;          /* r->args: raw query, no '?'         */
    ngx_str_t         unparsed_uri;  /* r->unparsed_uri: as sent           */
    ngx_str_t         addr_text;     /* r->connection->addr_text           */
    ngx_list_part_t  *headers;       /* &r->headers_in.headers.part        */
} ngx_http_isonim_request_view_t;

/* One response header, as Nim passes it to ngx_http_isonim_send_header.
 * The bytes belong to Nim and are copied into the request pool. */
typedef struct {
    const u_char  *key;
    size_t         key_len;
    const u_char  *value;
    size_t         value_len;
} ngx_http_isonim_header_t;

#define NGX_HTTP_ISONIM_MODE_STREAMING  0
#define NGX_HTTP_ISONIM_MODE_BUFFERED   1

/* ------------------------------------------------------------------ */
/* Nim entry points — defined in handler.nim, exported as C symbols.  */
/* ------------------------------------------------------------------ */

extern void nim_module_init(void);

extern ngx_int_t nim_handle_request(
    ngx_http_request_t *r,
    ngx_http_isonim_request_view_t *view, size_t view_size,
    const u_char *app_name, size_t app_name_len,
    ngx_int_t hydration,
    ngx_int_t buffered,
    size_t max_buffer_size);

/* The per-request state of an isonim_rpc request, in the request pool.
 * Created before the body is read, so that the body filter can count. */
typedef struct {
    ngx_http_request_t  *request;
    ngx_event_t          timeout;    /* isonim_rpc_timeout                  */
    void                *nim_state;  /* rpc.nim's RpcState (GC_ref'd)       */
    size_t               body_limit; /* isonim_rpc_max_body_size; 0 = none  */
    off_t                body_read;  /* body bytes seen by the body filter  */
} ngx_http_isonim_rpc_ctx_t;

/* rpc.nim: starts the request (the body is read).  Nim binds its state to
 * ctx (ngx_http_isonim_rpc_bind) before anything can finalize it. */
extern void nim_handle_rpc(
    ngx_http_request_t *r, ngx_http_isonim_rpc_ctx_t *ctx,
    ngx_http_isonim_request_view_t *view, size_t view_size,
    const u_char *body, size_t body_len,
    const u_char *app_name, size_t app_name_len);
/* rpc.nim: isonim_rpc_timeout expired. */
extern void nim_rpc_timeout(void *nim_state);
/* rpc.nim: the request pool is being destroyed; drop the state. */
extern void nim_rpc_released(void *nim_state);
/* async_loop.nim: run what is ready on Nim's event loop. */
extern void nim_async_pump(void);

static int nim_initialized = 0;

/* ------------------------------------------------------------------ */
/* Per-location configuration.                                        */
/* ------------------------------------------------------------------ */

typedef struct {
    ngx_flag_t  enabled;
    ngx_str_t   app_name;
    ngx_flag_t  hydration;
    ngx_uint_t  mode;
    size_t      max_buffer_size;

    ngx_flag_t  rpc_enabled;
    ngx_str_t   rpc_app;            /* "" = the server-function registry   */
    size_t      rpc_max_body_size;  /* 0 = unlimited                       */
    ngx_msec_t  rpc_timeout;        /* 0 = none                            */
} ngx_http_isonim_loc_conf_t;

/* Forward declarations */
static void      *ngx_http_isonim_create_loc_conf(ngx_conf_t *cf);
static char      *ngx_http_isonim_merge_loc_conf(ngx_conf_t *cf,
                      void *parent, void *child);
static ngx_int_t  ngx_http_isonim_postconfiguration(ngx_conf_t *cf);
static ngx_int_t  ngx_http_isonim_handler(ngx_http_request_t *r);
static void       ngx_http_isonim_exit_process(ngx_cycle_t *cycle);

/* ------------------------------------------------------------------ */
/* Directives                                                         */
/* ------------------------------------------------------------------ */

static ngx_conf_enum_t ngx_http_isonim_modes[] = {
    { ngx_string("streaming"), NGX_HTTP_ISONIM_MODE_STREAMING },
    { ngx_string("buffered"),  NGX_HTTP_ISONIM_MODE_BUFFERED },
    { ngx_null_string, 0 }
};

static ngx_command_t ngx_http_isonim_commands[] = {

    { ngx_string("isonim_ssr"),
      NGX_HTTP_LOC_CONF | NGX_CONF_FLAG,
      ngx_conf_set_flag_slot,
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_isonim_loc_conf_t, enabled),
      NULL },

    { ngx_string("isonim_ssr_app"),
      NGX_HTTP_LOC_CONF | NGX_CONF_TAKE1,
      ngx_conf_set_str_slot,
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_isonim_loc_conf_t, app_name),
      NULL },

    { ngx_string("isonim_ssr_hydration"),
      NGX_HTTP_LOC_CONF | NGX_CONF_FLAG,
      ngx_conf_set_flag_slot,
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_isonim_loc_conf_t, hydration),
      NULL },

    /* streaming (default): chunked, flushed as the renderer flushes.
     * buffered: the whole body is rendered first and sent with
     * Content-Length. */
    { ngx_string("isonim_ssr_mode"),
      NGX_HTTP_LOC_CONF | NGX_CONF_TAKE1,
      ngx_conf_set_enum_slot,
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_isonim_loc_conf_t, mode),
      &ngx_http_isonim_modes },

    /* Bytes, with nginx's k/m suffixes.  0 = unlimited. */
    { ngx_string("isonim_ssr_max_buffer_size"),
      NGX_HTTP_LOC_CONF | NGX_CONF_TAKE1,
      ngx_conf_set_size_slot,
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_isonim_loc_conf_t, max_buffer_size),
      NULL },

    /* Server functions over HTTP: the location reads request bodies
     * asynchronously and hands each request to the server-function
     * registry (POST <rpcPrefix>/<module>/<proc>) or, with isonim_rpc_app,
     * to an async app such as a route manifest's dispatch. */
    { ngx_string("isonim_rpc"),
      NGX_HTTP_LOC_CONF | NGX_CONF_FLAG,
      ngx_conf_set_flag_slot,
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_isonim_loc_conf_t, rpc_enabled),
      NULL },

    { ngx_string("isonim_rpc_app"),
      NGX_HTTP_LOC_CONF | NGX_CONF_TAKE1,
      ngx_conf_set_str_slot,
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_isonim_loc_conf_t, rpc_app),
      NULL },

    /* Bytes (k/m suffixes); larger bodies get 413.  0 = unlimited. */
    { ngx_string("isonim_rpc_max_body_size"),
      NGX_HTTP_LOC_CONF | NGX_CONF_TAKE1,
      ngx_conf_set_size_slot,
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_isonim_loc_conf_t, rpc_max_body_size),
      NULL },

    /* nginx time (ms, s, m, ...); a handler still running then gets 504.
     * 0 = no timeout. */
    { ngx_string("isonim_rpc_timeout"),
      NGX_HTTP_LOC_CONF | NGX_CONF_TAKE1,
      ngx_conf_set_msec_slot,
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_isonim_loc_conf_t, rpc_timeout),
      NULL },

    ngx_null_command
};

/* ------------------------------------------------------------------ */
/* Module context                                                     */
/* ------------------------------------------------------------------ */

static ngx_http_module_t ngx_http_isonim_module_ctx = {
    NULL,
    ngx_http_isonim_postconfiguration,
    NULL, NULL, NULL, NULL,
    ngx_http_isonim_create_loc_conf,
    ngx_http_isonim_merge_loc_conf
};

ngx_module_t ngx_http_isonim_module = {
    NGX_MODULE_V1,
    &ngx_http_isonim_module_ctx,
    ngx_http_isonim_commands,
    NGX_HTTP_MODULE,
    NULL,                                  /* init master    */
    NULL,                                  /* init module    */
    NULL,                                  /* init process   */
    NULL,                                  /* init thread    */
    NULL,                                  /* exit thread    */
    ngx_http_isonim_exit_process,          /* exit process   */
    NULL,                                  /* exit master    */
    NGX_MODULE_V1_PADDING
};

/* Dynamic module symbols */
ngx_module_t *ngx_modules[] = { &ngx_http_isonim_module, NULL };
char *ngx_module_names[] = { "ngx_http_isonim_module", NULL };
char *ngx_module_order[] = { NULL };

/* ------------------------------------------------------------------ */
/* create_loc_conf / merge_loc_conf                                   */
/* ------------------------------------------------------------------ */

static void *
ngx_http_isonim_create_loc_conf(ngx_conf_t *cf)
{
    ngx_http_isonim_loc_conf_t *conf;
    conf = ngx_pcalloc(cf->pool, sizeof(ngx_http_isonim_loc_conf_t));
    if (conf == NULL) return NULL;
    conf->enabled = NGX_CONF_UNSET;
    conf->hydration = NGX_CONF_UNSET;
    conf->mode = NGX_CONF_UNSET_UINT;
    conf->max_buffer_size = NGX_CONF_UNSET_SIZE;
    conf->rpc_enabled = NGX_CONF_UNSET;
    conf->rpc_max_body_size = NGX_CONF_UNSET_SIZE;
    conf->rpc_timeout = NGX_CONF_UNSET_MSEC;
    return conf;
}

static char *
ngx_http_isonim_merge_loc_conf(ngx_conf_t *cf, void *parent, void *child)
{
    ngx_http_isonim_loc_conf_t *prev = parent;
    ngx_http_isonim_loc_conf_t *conf = child;
    ngx_conf_merge_value(conf->enabled, prev->enabled, 0);
    ngx_conf_merge_str_value(conf->app_name, prev->app_name, "");
    ngx_conf_merge_value(conf->hydration, prev->hydration, 1);
    ngx_conf_merge_uint_value(conf->mode, prev->mode,
                              NGX_HTTP_ISONIM_MODE_STREAMING);
    ngx_conf_merge_size_value(conf->max_buffer_size, prev->max_buffer_size, 0);

    ngx_conf_merge_value(conf->rpc_enabled, prev->rpc_enabled, 0);
    ngx_conf_merge_str_value(conf->rpc_app, prev->rpc_app, "");
    ngx_conf_merge_size_value(conf->rpc_max_body_size, prev->rpc_max_body_size,
                              1024 * 1024);
    ngx_conf_merge_msec_value(conf->rpc_timeout, prev->rpc_timeout, 60000);

    if (conf->enabled && conf->app_name.len == 0) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "\"isonim_ssr on\" requires \"isonim_ssr_app\"");
        return NGX_CONF_ERROR;
    }

    if (conf->enabled && conf->rpc_enabled) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "\"isonim_ssr on\" and \"isonim_rpc on\" cannot "
                           "share a location");
        return NGX_CONF_ERROR;
    }

    if (conf->rpc_enabled && conf->rpc_max_body_size) {
        ngx_http_core_loc_conf_t *clcf;

        /* nginx refuses bodies over client_max_body_size before the module
         * sees them, so a larger isonim_rpc_max_body_size never applies. */
        clcf = ngx_http_conf_get_module_loc_conf(cf, ngx_http_core_module);
        if (clcf != NULL && clcf->client_max_body_size
            && clcf->client_max_body_size < (off_t) conf->rpc_max_body_size)
        {
            ngx_conf_log_error(NGX_LOG_WARN, cf, 0,
                "\"isonim_rpc_max_body_size\" (%uz) is larger than "
                "\"client_max_body_size\" (%O), which nginx enforces first",
                conf->rpc_max_body_size, clcf->client_max_body_size);
        }
    }
    return NGX_CONF_OK;
}

/* ------------------------------------------------------------------ */
/* Helpers called from Nim (serve.nim's nginx sink).                  */
/* ------------------------------------------------------------------ */

/* Sets the status, content type, content length and the renderer's
 * headers, then runs the header filters.  Called at most once per
 * request, before the first body byte.
 *
 * content_length < 0 leaves it unset (chunked on HTTP/1.1).
 *
 * Returns NGX_DONE when the response must carry no body (HEAD, 204, 304:
 * nginx set r->header_only), otherwise what ngx_http_send_header returned. */
ngx_int_t
ngx_http_isonim_send_header(ngx_http_request_t *r, ngx_uint_t status,
    const u_char *content_type, size_t content_type_len,
    off_t content_length,
    const ngx_http_isonim_header_t *headers, ngx_uint_t nheaders)
{
    ngx_uint_t        i;
    ngx_int_t         rc;
    ngx_table_elt_t  *h;
    u_char           *p;

    r->headers_out.status = status;
    r->headers_out.content_length_n = content_length;

    p = ngx_pnalloc(r->pool, content_type_len);
    if (p == NULL && content_type_len) return NGX_ERROR;
    ngx_memcpy(p, content_type, content_type_len);
    r->headers_out.content_type.data = p;
    r->headers_out.content_type.len = content_type_len;
    r->headers_out.content_type_len = content_type_len;
    r->headers_out.content_type_lowcase = NULL;

    for (i = 0; i < nheaders; i++) {
        h = ngx_list_push(&r->headers_out.headers);
        if (h == NULL) return NGX_ERROR;

        h->key.data = ngx_pnalloc(r->pool, headers[i].key_len);
        h->value.data = ngx_pnalloc(r->pool, headers[i].value_len + 1);
        if ((h->key.data == NULL && headers[i].key_len)
            || h->value.data == NULL)
        {
            return NGX_ERROR;
        }
        ngx_memcpy(h->key.data, headers[i].key, headers[i].key_len);
        h->key.len = headers[i].key_len;
        ngx_memcpy(h->value.data, headers[i].value, headers[i].value_len);
        h->value.data[headers[i].value_len] = '\0';
        h->value.len = headers[i].value_len;
        h->hash = 1;
        h->lowcase_key = NULL;
        h->next = NULL;
    }

    rc = ngx_http_send_header(r);
    if (rc == NGX_ERROR || rc > NGX_OK) return rc;
    if (r->header_only) return NGX_DONE;
    return rc;
}

/* Passes len bytes (copied into the request pool) down the output filter
 * chain.  flush asks the write filter to put them on the wire now instead
 * of waiting for postpone_output bytes; last marks the end of the response
 * (the chunked filter then writes the terminating chunk).  Returns what
 * ngx_http_output_filter returned. */
ngx_int_t
ngx_http_isonim_send_body(ngx_http_request_t *r, const u_char *data,
    size_t len, ngx_flag_t flush, ngx_flag_t last)
{
    ngx_buf_t    *b;
    ngx_chain_t   out;

    if (len == 0 && !flush && !last) return NGX_OK;

    if (len > 0) {
        b = ngx_create_temp_buf(r->pool, len);
        if (b == NULL) return NGX_ERROR;
        b->last = ngx_cpymem(b->pos, data, len);
    } else {
        b = ngx_calloc_buf(r->pool);
        if (b == NULL) return NGX_ERROR;
    }

    b->flush = flush ? 1 : 0;
    if (last) {
        b->last_buf = (r == r->main) ? 1 : 0;
        b->last_in_chain = 1;
    }

    out.buf = b;
    out.next = NULL;
    return ngx_http_output_filter(r, &out);
}

/* Writes one line to the request's error log. */
void
ngx_http_isonim_log(ngx_http_request_t *r, ngx_uint_t level,
    const u_char *msg, size_t len)
{
    ngx_log_error(level, r->connection->log, 0, "isonim: %*s", len, msg);
}

/* ------------------------------------------------------------------ */
/* Content handler                                                    */
/* ------------------------------------------------------------------ */

static void
ngx_http_isonim_fill_view(ngx_http_request_t *r,
    ngx_http_isonim_request_view_t *view)
{
    view->method = r->method_name;
    view->uri = r->uri;
    view->args = r->args;
    view->unparsed_uri = r->unparsed_uri;
    view->addr_text = r->connection->addr_text;
    view->headers = &r->headers_in.headers.part;
}

static void
ngx_http_isonim_init_nim(void)
{
    if (!nim_initialized) {
        nim_module_init();
        nim_initialized = 1;
    }
}

static ngx_int_t ngx_http_isonim_rpc_handler(ngx_http_request_t *r,
    ngx_http_isonim_loc_conf_t *conf);

static ngx_int_t
ngx_http_isonim_handler(ngx_http_request_t *r)
{
    ngx_http_isonim_loc_conf_t      *conf;
    ngx_http_isonim_request_view_t   view;
    ngx_int_t                        rc;

    conf = ngx_http_get_module_loc_conf(r, ngx_http_isonim_module);
    if (conf == NULL) return NGX_DECLINED;

    if (conf->rpc_enabled) {
        ngx_http_isonim_init_nim();
        return ngx_http_isonim_rpc_handler(r, conf);
    }

    if (!conf->enabled) return NGX_DECLINED;

    ngx_http_isonim_init_nim();

    rc = ngx_http_discard_request_body(r);
    if (rc != NGX_OK) return rc;

    ngx_http_isonim_fill_view(r, &view);

    return nim_handle_request(r, &view, sizeof(view),
        conf->app_name.data, conf->app_name.len,
        conf->hydration,
        conf->mode == NGX_HTTP_ISONIM_MODE_BUFFERED,
        conf->max_buffer_size);
}

/* ------------------------------------------------------------------ */
/* isonim_rpc: read the body, then hand the request to Nim.           */
/* ------------------------------------------------------------------ */

/* Finalizes the request with rc.  Nim calls this exactly once per
 * isonim_rpc request: after the response is sent, or with a status code
 * for nginx to answer (e.g. 500 when nothing was sent). */
void
ngx_http_isonim_finalize(ngx_http_request_t *r, ngx_int_t rc)
{
    ngx_http_isonim_rpc_ctx_t  *ctx;

    ctx = ngx_http_get_module_ctx(r, ngx_http_isonim_module);
    if (ctx != NULL && ctx->timeout.timer_set) {
        ngx_del_timer(&ctx->timeout);
    }
    ngx_http_finalize_request(r, rc);
}

/* Binds rpc.nim's state to the request, so that the timeout and the
 * pool cleanup can reach it. */
void
ngx_http_isonim_rpc_bind(ngx_http_isonim_rpc_ctx_t *ctx, void *nim_state)
{
    ctx->nim_state = nim_state;
}

static void
ngx_http_isonim_rpc_timeout_handler(ngx_event_t *ev)
{
    ngx_http_isonim_rpc_ctx_t  *ctx = ev->data;

    if (ctx->nim_state != NULL) {
        nim_rpc_timeout(ctx->nim_state);
        nim_async_pump();
    }
}

/* The request pool is being destroyed (the request finished, or the
 * client went away and nginx terminated it): stop the timer, and let Nim
 * drop its state.  A handler still running in Nim completes later and
 * finds its request gone. */
static void
ngx_http_isonim_rpc_cleanup(void *data)
{
    ngx_http_isonim_rpc_ctx_t  *ctx = data;
    void                       *state;

    if (ctx->timeout.timer_set) {
        ngx_del_timer(&ctx->timeout);
    }
    state = ctx->nim_state;
    ctx->nim_state = NULL;
    if (state != NULL) {
        nim_rpc_released(state);
    }
}

/* Copies the request body (memory or temporary-file buffers) into one
 * pool buffer.  Sets *len; returns NULL with *len = 0 for no body, and
 * (u_char *) -1 on a read or allocation error. */
static u_char *
ngx_http_isonim_collect_body(ngx_http_request_t *r, size_t *len)
{
    ngx_chain_t  *cl;
    ngx_buf_t    *b;
    u_char       *body, *p;
    size_t        size;
    ssize_t       n;

    *len = 0;
    if (r->request_body == NULL || r->request_body->bufs == NULL) {
        return NULL;
    }
    for (cl = r->request_body->bufs; cl; cl = cl->next) {
        *len += ngx_buf_size(cl->buf);
    }
    if (*len == 0) {
        return NULL;
    }
    body = ngx_pnalloc(r->pool, *len);
    if (body == NULL) {
        return (u_char *) -1;
    }
    p = body;
    for (cl = r->request_body->bufs; cl; cl = cl->next) {
        b = cl->buf;
        if (b->in_file) {
            size = (size_t) (b->file_last - b->file_pos);
            n = ngx_read_file(b->file, p, size, b->file_pos);
            if (n != (ssize_t) size) {
                return (u_char *) -1;
            }
            p += size;
        } else {
            p = ngx_cpymem(p, b->pos, b->last - b->pos);
        }
    }
    return body;
}

static void
ngx_http_isonim_rpc_body_handler(ngx_http_request_t *r)
{
    ngx_http_isonim_loc_conf_t      *conf;
    ngx_http_isonim_rpc_ctx_t       *ctx;
    ngx_http_isonim_request_view_t   view;
    ngx_pool_cleanup_t              *cln;
    u_char                          *body;
    size_t                           len;

    conf = ngx_http_get_module_loc_conf(r, ngx_http_isonim_module);

    body = ngx_http_isonim_collect_body(r, &len);
    if (body == (u_char *) -1) {
        ngx_http_finalize_request(r, NGX_HTTP_INTERNAL_SERVER_ERROR);
        return;
    }

    /* The body filter refused anything larger while reading; this is the
     * backstop. */
    if (conf->rpc_max_body_size && len > conf->rpc_max_body_size) {
        ngx_log_error(NGX_LOG_INFO, r->connection->log, 0,
                      "isonim: request body of %uz bytes exceeds "
                      "isonim_rpc_max_body_size (%uz)",
                      len, conf->rpc_max_body_size);
        ngx_http_finalize_request(r, NGX_HTTP_REQUEST_ENTITY_TOO_LARGE);
        return;
    }

    ctx = ngx_http_get_module_ctx(r, ngx_http_isonim_module);
    cln = ngx_pool_cleanup_add(r->pool, 0);
    if (ctx == NULL || cln == NULL) {
        ngx_http_finalize_request(r, NGX_HTTP_INTERNAL_SERVER_ERROR);
        return;
    }
    ctx->timeout.handler = ngx_http_isonim_rpc_timeout_handler;
    ctx->timeout.data = ctx;
    ctx->timeout.log = r->connection->log;
    cln->handler = ngx_http_isonim_rpc_cleanup;
    cln->data = ctx;

    if (conf->rpc_timeout) {
        ngx_add_timer(&ctx->timeout, conf->rpc_timeout);
    }

    /* While Nim works, notice a client that closes the connection: nginx
     * then terminates the request (499) and the cleanup above runs. */
    r->read_event_handler = ngx_http_test_reading;

    ngx_http_isonim_fill_view(r, &view);
    nim_handle_rpc(r, ctx, &view, sizeof(view), body, len,
                   conf->rpc_app.data, conf->rpc_app.len);
}

static ngx_http_request_body_filter_pt  ngx_http_isonim_next_body_filter;

/* Counts the body of an isonim_rpc request as nginx reads it (after
 * Content-Length or chunked decoding) and refuses it with 413 as soon as the
 * running total exceeds isonim_rpc_max_body_size: nginx then stops reading,
 * so neither its buffers nor its temporary file nor the module's copy
 * (ngx_http_isonim_collect_body) ever holds more than the limit, even with
 * client_max_body_size 0. */
static ngx_int_t
ngx_http_isonim_rpc_body_filter(ngx_http_request_t *r, ngx_chain_t *in)
{
    ngx_http_isonim_rpc_ctx_t  *ctx;
    ngx_chain_t                *cl;

    ctx = ngx_http_get_module_ctx(r, ngx_http_isonim_module);
    if (ctx != NULL && ctx->request == r && ctx->body_limit) {
        for (cl = in; cl; cl = cl->next) {
            ctx->body_read += ngx_buf_size(cl->buf);
        }
        if (ctx->body_read > (off_t) ctx->body_limit) {
            ngx_log_error(NGX_LOG_INFO, r->connection->log, 0,
                          "isonim: request body exceeds "
                          "isonim_rpc_max_body_size (%uz) after %O bytes "
                          "read; refused while reading",
                          ctx->body_limit, ctx->body_read);
            r->lingering_close = 1;
            return NGX_HTTP_REQUEST_ENTITY_TOO_LARGE;
        }
    }
    return ngx_http_isonim_next_body_filter(r, in);
}

static ngx_int_t
ngx_http_isonim_rpc_handler(ngx_http_request_t *r,
    ngx_http_isonim_loc_conf_t *conf)
{
    ngx_int_t                   rc;
    ngx_http_isonim_rpc_ctx_t  *ctx;

    if (conf->rpc_max_body_size
        && r->headers_in.content_length_n > (off_t) conf->rpc_max_body_size)
    {
        ngx_log_error(NGX_LOG_INFO, r->connection->log, 0,
                      "isonim: Content-Length %O exceeds "
                      "isonim_rpc_max_body_size (%uz)",
                      r->headers_in.content_length_n,
                      conf->rpc_max_body_size);
        return NGX_HTTP_REQUEST_ENTITY_TOO_LARGE;
    }

    /* The request's state exists before the body is read: the body filter
     * counts into it. */
    ctx = ngx_pcalloc(r->pool, sizeof(ngx_http_isonim_rpc_ctx_t));
    if (ctx == NULL) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }
    ctx->request = r;
    ctx->body_limit = conf->rpc_max_body_size;
    ngx_http_set_ctx(r, ctx, ngx_http_isonim_module);

    /* Temporary body files are removed with the request. */
    r->request_body_in_clean_file = 1;

    rc = ngx_http_read_client_request_body(r, ngx_http_isonim_rpc_body_handler);
    if (rc >= NGX_HTTP_SPECIAL_RESPONSE) {
        return rc;
    }
    return NGX_DONE;
}

/* ------------------------------------------------------------------ */
/* Nim's event loop inside the worker's (async_loop.nim)              */
/* ------------------------------------------------------------------ */

static ngx_event_t        ngx_http_isonim_pump_timer;
static ngx_connection_t  *ngx_http_isonim_loop_conn;

static void
ngx_http_isonim_pump_handler(ngx_event_t *ev)
{
    nim_async_pump();
}

/* Arms the timer that runs Nim's event loop in msec milliseconds
 * (re-arming replaces it); a negative msec cancels it. */
void
ngx_http_isonim_async_arm(ngx_int_t msec)
{
    ngx_event_t  *ev = &ngx_http_isonim_pump_timer;

    if (ev->handler == NULL) {
        ev->handler = ngx_http_isonim_pump_handler;
        ev->log = ngx_cycle->log;
        /* Never keeps a gracefully exiting worker alive. */
        ev->cancelable = 1;
    }
    if (msec < 0) {
        if (ev->timer_set) {
            ngx_del_timer(ev);
        }
        return;
    }
    ngx_add_timer(ev, (ngx_msec_t) msec);
}

/* Watches Nim's dispatcher descriptor (an epoll fd, readable whenever a
 * descriptor registered with it is ready): level-triggered, so it keeps
 * firing until Nim has consumed what is ready.  Returns NGX_OK or
 * NGX_ERROR. */
ngx_int_t
ngx_http_isonim_async_watch_fd(ngx_int_t fd)
{
    ngx_connection_t  *c;

    if (ngx_http_isonim_loop_conn != NULL) {
        return NGX_OK;
    }
    c = ngx_get_connection((ngx_socket_t) fd, ngx_cycle->log);
    if (c == NULL) {
        return NGX_ERROR;
    }
    c->read->handler = ngx_http_isonim_pump_handler;
    c->read->log = ngx_cycle->log;
    c->write->log = ngx_cycle->log;
    if (ngx_add_event(c->read, NGX_READ_EVENT, NGX_LEVEL_EVENT) != NGX_OK) {
        ngx_free_connection(c);
        return NGX_ERROR;
    }
    ngx_http_isonim_loop_conn = c;
    return NGX_OK;
}

/* Writes one line to the worker's error log (no request at hand). */
void
ngx_http_isonim_log_cycle(ngx_uint_t level, const u_char *msg, size_t len)
{
    ngx_log_error(level, ngx_cycle->log, 0, "isonim: %*s", len, msg);
}

static void
ngx_http_isonim_exit_process(ngx_cycle_t *cycle)
{
    ngx_connection_t  *c = ngx_http_isonim_loop_conn;

    /* The descriptor is Nim's; detach it from nginx before nginx checks
     * for connections left open. */
    if (c != NULL) {
        ngx_del_event(c->read, NGX_READ_EVENT, 0);
        c->fd = (ngx_socket_t) -1;
        ngx_free_connection(c);
        ngx_http_isonim_loop_conn = NULL;
    }
    if (ngx_http_isonim_pump_timer.timer_set) {
        ngx_del_timer(&ngx_http_isonim_pump_timer);
    }
}

/* ------------------------------------------------------------------ */
/* postconfiguration — the content handler and the body filter       */
/* ------------------------------------------------------------------ */

static ngx_int_t
ngx_http_isonim_postconfiguration(ngx_conf_t *cf)
{
    ngx_http_handler_pt        *h;
    ngx_http_core_main_conf_t  *cmcf;

    cmcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_core_module);
    h = ngx_array_push(&cmcf->phases[NGX_HTTP_CONTENT_PHASE].handlers);
    if (h == NULL) return NGX_ERROR;

    /* One handler for both transports; isonim_ssr_mode picks streaming
     * (the default) or buffered per location. */
    *h = ngx_http_isonim_handler;

    /* isonim_rpc_max_body_size while the body is read. */
    ngx_http_isonim_next_body_filter = ngx_http_top_request_body_filter;
    ngx_http_top_request_body_filter = ngx_http_isonim_rpc_body_filter;

    return NGX_OK;
}
