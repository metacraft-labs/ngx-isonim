/*
 * ngx_http_isonim_module.c
 *
 * nginx HTTP module for IsoNim server-side rendering.
 *
 * This C file is the entry point that nginx loads as a dynamic shared
 * object.  It defines:
 *
 *   - the per-location configuration (the isonim_ssr* directives);
 *   - the content handler, which hands the request to Nim;
 *   - a small set of helpers that Nim calls back into to send the response
 *     (status and headers, body buffers, error log lines).  They live here
 *     because they touch nginx structures (headers_out, ngx_buf_t bitfields,
 *     the connection log) that are clearer to manipulate from C.
 *
 * Request handling itself (method check, app lookup, rendering, response
 * shaping, the hydration script and its per-response CSP nonce, the
 * isonim_ssr_max_buffer_size limit, and the streaming or buffered transport)
 * lives in serve.nim and is shared with the mock-mode unit tests.
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
} ngx_http_isonim_loc_conf_t;

/* Forward declarations */
static void      *ngx_http_isonim_create_loc_conf(ngx_conf_t *cf);
static char      *ngx_http_isonim_merge_loc_conf(ngx_conf_t *cf,
                      void *parent, void *child);
static ngx_int_t  ngx_http_isonim_postconfiguration(ngx_conf_t *cf);
static ngx_int_t  ngx_http_isonim_handler(ngx_http_request_t *r);

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
    NULL, NULL, NULL, NULL, NULL, NULL, NULL,
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

    if (conf->enabled && conf->app_name.len == 0) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "\"isonim_ssr on\" requires \"isonim_ssr_app\"");
        return NGX_CONF_ERROR;
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

static ngx_int_t
ngx_http_isonim_handler(ngx_http_request_t *r)
{
    ngx_http_isonim_loc_conf_t      *conf;
    ngx_http_isonim_request_view_t   view;
    ngx_int_t                        rc;

    conf = ngx_http_get_module_loc_conf(r, ngx_http_isonim_module);
    if (conf == NULL || !conf->enabled) return NGX_DECLINED;

    if (!nim_initialized) {
        nim_module_init();
        nim_initialized = 1;
    }

    rc = ngx_http_discard_request_body(r);
    if (rc != NGX_OK) return rc;

    view.method = r->method_name;
    view.uri = r->uri;
    view.args = r->args;
    view.unparsed_uri = r->unparsed_uri;
    view.addr_text = r->connection->addr_text;
    view.headers = &r->headers_in.headers.part;

    return nim_handle_request(r, &view, sizeof(view),
        conf->app_name.data, conf->app_name.len,
        conf->hydration,
        conf->mode == NGX_HTTP_ISONIM_MODE_BUFFERED,
        conf->max_buffer_size);
}

/* ------------------------------------------------------------------ */
/* postconfiguration — register the content handler                   */
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

    return NGX_OK;
}
