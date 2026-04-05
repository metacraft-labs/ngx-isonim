/*
 * ngx_http_isonim_module.c
 *
 * nginx HTTP module for IsoNim server-side rendering.
 *
 * This C file is the entry point that nginx loads as a dynamic shared
 * object.  It defines:
 *
 *   - Per-location configuration (isonim_ssr directives)
 *   - A content handler that delegates SSR to Nim code
 *   - Two rendering paths: buffered (string) and streaming (faststreams)
 *
 * The rendering logic lives in handler.nim (compiled to C and linked
 * into the same .so).
 */

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>

/* ------------------------------------------------------------------ */
/* Nim entry points — defined in handler.nim, exported as C symbols.  */
/*                                                                    */
/* Two rendering paths:                                               */
/*                                                                    */
/*   1. STREAMING: nim_render_streaming                               */
/*      Writes directly to the nginx output chain via faststreams.    */
/*      No intermediate string copy.  Requires release build.        */
/*                                                                    */
/*   2. BUFFERED: nim_render_app + nim_free_html                      */
/*      Renders to a Nim string, copies to C buffer, sends as one     */
/*      ngx_buf_t.  Stable under all build modes.                     */
/* ------------------------------------------------------------------ */

extern void nim_module_init(void);

/* Streaming path */
extern ngx_int_t nim_render_streaming(
    void *request, void *pool,
    const char *app_name, int app_name_len,
    int hydration_enabled,
    const char *script_nonce, int script_nonce_len);

/* Buffered path */
extern ngx_int_t nim_render_app(
    const char *app_name, int app_name_len,
    int hydration_enabled,
    const char *script_nonce, int script_nonce_len,
    char **out_html, int *out_len);

extern void nim_free_html(char *html);

static int nim_initialized = 0;

/* ------------------------------------------------------------------ */
/* Per-location configuration.                                        */
/* ------------------------------------------------------------------ */

typedef struct {
    ngx_flag_t  enabled;
    ngx_str_t   app_name;
    ngx_flag_t  hydration;
    ngx_str_t   script_nonce;
    ngx_int_t   max_buffer_size;
} ngx_http_isonim_loc_conf_t;

/* Forward declarations */
static void      *ngx_http_isonim_create_loc_conf(ngx_conf_t *cf);
static char      *ngx_http_isonim_merge_loc_conf(ngx_conf_t *cf,
                      void *parent, void *child);
static ngx_int_t  ngx_http_isonim_postconfiguration(ngx_conf_t *cf);
static ngx_int_t  ngx_http_isonim_handler(ngx_http_request_t *r);
static ngx_int_t  ngx_http_isonim_streaming_handler(ngx_http_request_t *r);

/* ------------------------------------------------------------------ */
/* Directives                                                         */
/* ------------------------------------------------------------------ */

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

    { ngx_string("isonim_ssr_script_nonce"),
      NGX_HTTP_LOC_CONF | NGX_CONF_TAKE1,
      ngx_conf_set_str_slot,
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_isonim_loc_conf_t, script_nonce),
      NULL },

    { ngx_string("isonim_ssr_max_buffer_size"),
      NGX_HTTP_LOC_CONF | NGX_CONF_TAKE1,
      ngx_conf_set_num_slot,
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
    conf->max_buffer_size = NGX_CONF_UNSET;
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
    ngx_conf_merge_str_value(conf->script_nonce, prev->script_nonce, "");
    ngx_conf_merge_value(conf->max_buffer_size, prev->max_buffer_size, 0);
    return NGX_CONF_OK;
}

/* ------------------------------------------------------------------ */
/* BUFFERED content handler                                           */
/*                                                                    */
/* Calls nim_render_app to get the full HTML string, then sends it    */
/* as a single ngx_buf_t with Content-Length.                         */
/* ------------------------------------------------------------------ */

static ngx_int_t
ngx_http_isonim_handler(ngx_http_request_t *r)
{
    ngx_http_isonim_loc_conf_t *conf;
    char       *html = NULL;
    int         html_len = 0;
    ngx_int_t   rc;
    ngx_buf_t  *b;
    ngx_chain_t out;

    if (!nim_initialized) {
        nim_module_init();
        nim_initialized = 1;
    }

    conf = ngx_http_get_module_loc_conf(r, ngx_http_isonim_module);
    if (conf == NULL || !conf->enabled) return NGX_DECLINED;
    if (!(r->method & (NGX_HTTP_GET | NGX_HTTP_HEAD)))
        return NGX_HTTP_NOT_ALLOWED;

    rc = ngx_http_discard_request_body(r);
    if (rc != NGX_OK) return rc;

    /* Render via Nim */
    rc = nim_render_app(
        (const char *)conf->app_name.data, (int)conf->app_name.len,
        (int)conf->hydration,
        (const char *)conf->script_nonce.data, (int)conf->script_nonce.len,
        &html, &html_len);

    if (rc != NGX_OK || html == NULL)
        return NGX_HTTP_INTERNAL_SERVER_ERROR;

    /* Send headers */
    r->headers_out.status = NGX_HTTP_OK;
    r->headers_out.content_length_n = html_len;
    r->headers_out.content_type_len = sizeof("text/html; charset=utf-8") - 1;
    ngx_str_set(&r->headers_out.content_type, "text/html; charset=utf-8");

    rc = ngx_http_send_header(r);
    if (rc == NGX_ERROR || rc > NGX_OK || r->header_only) {
        nim_free_html(html);
        return rc;
    }

    /* Send body */
    b = ngx_create_temp_buf(r->pool, html_len);
    if (b == NULL) { nim_free_html(html); return NGX_HTTP_INTERNAL_SERVER_ERROR; }
    ngx_memcpy(b->pos, html, html_len);
    b->last = b->pos + html_len;
    b->memory = 1;
    b->last_buf = 1;
    b->last_in_chain = 1;

    nim_free_html(html);

    out.buf = b;
    out.next = NULL;
    return ngx_http_output_filter(r, &out);
}

/* ------------------------------------------------------------------ */
/* STREAMING content handler                                          */
/*                                                                    */
/* Writes HTML directly to the output chain via faststreams.           */
/* No intermediate string copy.  Requires release build (debug hangs).*/
/* ------------------------------------------------------------------ */

static ngx_int_t
ngx_http_isonim_streaming_handler(ngx_http_request_t *r)
{
    ngx_http_isonim_loc_conf_t *conf;
    ngx_int_t rc;

    if (!nim_initialized) {
        nim_module_init();
        nim_initialized = 1;
    }

    conf = ngx_http_get_module_loc_conf(r, ngx_http_isonim_module);
    if (conf == NULL || !conf->enabled) return NGX_DECLINED;
    if (!(r->method & (NGX_HTTP_GET | NGX_HTTP_HEAD)))
        return NGX_HTTP_NOT_ALLOWED;

    rc = ngx_http_discard_request_body(r);
    if (rc != NGX_OK) return rc;

    /* Send headers (chunked — no Content-Length) */
    r->headers_out.status = NGX_HTTP_OK;
    r->headers_out.content_type_len = sizeof("text/html; charset=utf-8") - 1;
    ngx_str_set(&r->headers_out.content_type, "text/html; charset=utf-8");
    r->headers_out.content_length_n = -1;

    rc = ngx_http_send_header(r);
    if (rc == NGX_ERROR || rc > NGX_OK || r->header_only) return rc;

    /* Render directly into the output chain */
    return nim_render_streaming(
        (void *)r, (void *)r->pool,
        (const char *)conf->app_name.data, (int)conf->app_name.len,
        (int)conf->hydration,
        (const char *)conf->script_nonce.data, (int)conf->script_nonce.len);
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

    /* Buffered handler is stable under all build modes.
     * Streaming is faster but requires release build (debug hangs).
     * Switch with: *h = ngx_http_isonim_streaming_handler; */
    *h = ngx_http_isonim_handler;

    return NGX_OK;
}
