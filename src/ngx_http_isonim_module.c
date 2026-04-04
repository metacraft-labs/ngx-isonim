/*
 * ngx_http_isonim_module.c
 *
 * nginx HTTP module for IsoNim server-side rendering.
 *
 * This C file is the entry point that nginx loads (either statically linked
 * or as a dynamic shared object).  It defines:
 *
 *   - The per-location configuration structure and its lifecycle callbacks
 *     (create_loc_conf / merge_loc_conf).
 *   - Five nginx.conf directives for controlling the SSR behaviour per
 *     location block.
 *   - A postconfiguration hook that installs the content-phase handler.
 *   - The content handler itself, which delegates to Nim code compiled
 *     alongside this module.
 *
 * The actual rendering logic lives in handler.nim, which is compiled to C
 * by the Nim compiler and linked into the same .so.  The bridge between
 * the two languages is the single extern function `nim_handle_request`.
 */

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>

/* ------------------------------------------------------------------ */
/* Nim entry points — defined in handler.nim, exported as C symbols.  */
/*                                                                    */
/* Two rendering paths are available:                                 */
/*                                                                    */
/*   1. STREAMING (production):  nim_render_streaming                 */
/*      Writes HTML directly to the nginx output chain through a      */
/*      faststreams OutputStream.  No intermediate string copy.       */
/*      This is the path registered in postconfiguration.             */
/*                                                                    */
/*   2. BUFFERED (baseline):  nim_render_app + nim_free_html          */
/*      Builds the full HTML as a Nim string, copies it to a          */
/*      C-allocated buffer, then sends it as a single ngx_buf_t.     */
/*      Kept as a reference for performance comparisons and as a      */
/*      fallback until the streaming path has more production          */
/*      mileage.  To switch back, change postconfiguration to         */
/*      register ngx_http_isonim_handler instead of                   */
/*      ngx_http_isonim_streaming_handler.                            */
/* ------------------------------------------------------------------ */

/* Initialize the Nim GC and register default apps. Called once. */
extern void nim_module_init(void);

/* --- Streaming path (production) ---------------------------------- */

/* Writes HTML directly to the nginx output chain via a faststreams
 * OutputStream wrapping ngx_buf_t / ngx_http_output_filter.
 * Headers must be sent before calling.
 * Returns NGX_OK on success, NGX_ERROR on failure. */
extern ngx_int_t nim_render_streaming(
    void *request, void *pool,
    const char *app_name, int app_name_len,
    int hydration_enabled,
    const char *script_nonce, int script_nonce_len);

/* --- Buffered path (baseline for comparison) ---------------------- */

/* Render an app by name. Returns NGX_OK on success and sets *out_html
 * and *out_len.  The caller must free *out_html via nim_free_html(). */
extern ngx_int_t nim_render_app(
    const char *app_name, int app_name_len,
    int hydration_enabled,
    const char *script_nonce, int script_nonce_len,
    char **out_html, int *out_len);

/* Free HTML buffer previously returned by nim_render_app. */
extern void nim_free_html(char *html);

/* Flag to ensure nim_module_init is called exactly once. */
static int nim_initialized = 0;

/* ------------------------------------------------------------------ */
/* Per-location configuration.                                        */
/*                                                                    */
/* One instance is created for every location block that contains     */
/* any of the isonim_ssr* directives.  Unset values use               */
/* NGX_CONF_UNSET / NGX_CONF_UNSET_PTR so that merge_loc_conf can    */
/* inherit from the parent location.                                  */
/* ------------------------------------------------------------------ */
typedef struct {
    ngx_flag_t  enabled;          /* isonim_ssr on|off               */
    ngx_str_t   app_name;         /* isonim_ssr_app <name>           */
    ngx_flag_t  hydration;        /* isonim_ssr_hydration on|off     */
    ngx_str_t   script_nonce;     /* isonim_ssr_script_nonce <nonce> */
    ngx_int_t   max_buffer_size;  /* isonim_ssr_max_buffer_size <sz> */
} ngx_http_isonim_loc_conf_t;

/* ------------------------------------------------------------------ */
/* Forward declarations.                                              */
/* ------------------------------------------------------------------ */
static void      *ngx_http_isonim_create_loc_conf(ngx_conf_t *cf);
static char      *ngx_http_isonim_merge_loc_conf(ngx_conf_t *cf,
                      void *parent, void *child);
static ngx_int_t  ngx_http_isonim_postconfiguration(ngx_conf_t *cf);
static ngx_int_t  ngx_http_isonim_handler(ngx_http_request_t *r);
static ngx_int_t  ngx_http_isonim_streaming_handler(ngx_http_request_t *r);

/* ------------------------------------------------------------------ */
/* Directive table.                                                   */
/*                                                                    */
/* Each entry maps a directive name to the built-in nginx set-handler */
/* (flag, string, or numeric) and the corresponding field offset      */
/* inside ngx_http_isonim_loc_conf_t.                                 */
/* ------------------------------------------------------------------ */
static ngx_command_t ngx_http_isonim_commands[] = {

    /* isonim_ssr on|off — enable/disable SSR for this location. */
    { ngx_string("isonim_ssr"),
      NGX_HTTP_LOC_CONF | NGX_CONF_FLAG,
      ngx_conf_set_flag_slot,
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_isonim_loc_conf_t, enabled),
      NULL },

    /* isonim_ssr_app <name> — which registered app to render. */
    { ngx_string("isonim_ssr_app"),
      NGX_HTTP_LOC_CONF | NGX_CONF_TAKE1,
      ngx_conf_set_str_slot,
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_isonim_loc_conf_t, app_name),
      NULL },

    /* isonim_ssr_hydration on|off — include hydration bootstrap script. */
    { ngx_string("isonim_ssr_hydration"),
      NGX_HTTP_LOC_CONF | NGX_CONF_FLAG,
      ngx_conf_set_flag_slot,
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_isonim_loc_conf_t, hydration),
      NULL },

    /* isonim_ssr_script_nonce <nonce> — CSP nonce for inline scripts. */
    { ngx_string("isonim_ssr_script_nonce"),
      NGX_HTTP_LOC_CONF | NGX_CONF_TAKE1,
      ngx_conf_set_str_slot,
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_isonim_loc_conf_t, script_nonce),
      NULL },

    /* isonim_ssr_max_buffer_size <size> — response buffer limit in bytes. */
    { ngx_string("isonim_ssr_max_buffer_size"),
      NGX_HTTP_LOC_CONF | NGX_CONF_TAKE1,
      ngx_conf_set_num_slot,
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_isonim_loc_conf_t, max_buffer_size),
      NULL },

    ngx_null_command
};

/* ------------------------------------------------------------------ */
/* Module context — tells nginx which lifecycle callbacks we provide.  */
/* ------------------------------------------------------------------ */
static ngx_http_module_t ngx_http_isonim_module_ctx = {
    NULL,                                   /* preconfiguration        */
    ngx_http_isonim_postconfiguration,      /* postconfiguration       */
    NULL,                                   /* create main conf        */
    NULL,                                   /* init main conf          */
    NULL,                                   /* create server conf      */
    NULL,                                   /* merge server conf       */
    ngx_http_isonim_create_loc_conf,        /* create location conf    */
    ngx_http_isonim_merge_loc_conf          /* merge location conf     */
};

/* ------------------------------------------------------------------ */
/* Module definition — the symbol nginx resolves when loading the     */
/* shared object.  Must be named exactly                              */
/* `ngx_http_isonim_module` to match the config module line.          */
/* ------------------------------------------------------------------ */
ngx_module_t ngx_http_isonim_module = {
    NGX_MODULE_V1,
    &ngx_http_isonim_module_ctx,    /* module context    */
    ngx_http_isonim_commands,       /* module directives */
    NGX_HTTP_MODULE,                /* module type       */
    NULL,                           /* init master       */
    NULL,                           /* init module       */
    NULL,                           /* init process      */
    NULL,                           /* init thread       */
    NULL,                           /* exit thread       */
    NULL,                           /* exit process      */
    NULL,                           /* exit master       */
    NGX_MODULE_V1_PADDING
};

/* ------------------------------------------------------------------ */
/* Dynamic module loading support.                                    */
/*                                                                    */
/* When nginx loads a dynamic module (.so via load_module), it looks  */
/* for these two symbols to discover the module(s) inside:            */
/*   ngx_modules    — NULL-terminated array of module pointers        */
/*   ngx_module_names — NULL-terminated array of module name strings  */
/*                                                                    */
/* For static linking these are generated by nginx's configure script */
/* into objs/ngx_modules.c, but for dynamic modules we must provide  */
/* them ourselves.                                                    */
/* ------------------------------------------------------------------ */
ngx_module_t *ngx_modules[] = {
    &ngx_http_isonim_module,
    NULL
};

char *ngx_module_names[] = {
    "ngx_http_isonim_module",
    NULL
};

/* nginx also checks this to verify the module was compiled against a */
/* compatible version. It must match nginx's own ngx_module_order.    */
char *ngx_module_order[] = {
    NULL
};

/* ------------------------------------------------------------------ */
/* create_loc_conf                                                    */
/*                                                                    */
/* Allocate a fresh per-location config and set all fields to their   */
/* "unset" sentinel values.  String fields are implicitly zeroed by   */
/* ngx_pcalloc (ngx_str_t is {0, NULL}).                              */
/* ------------------------------------------------------------------ */
static void *
ngx_http_isonim_create_loc_conf(ngx_conf_t *cf)
{
    ngx_http_isonim_loc_conf_t *conf;

    conf = ngx_pcalloc(cf->pool, sizeof(ngx_http_isonim_loc_conf_t));
    if (conf == NULL) {
        return NULL;
    }

    /* Flag and numeric fields need explicit unset sentinels so that
     * merge_loc_conf can distinguish "not set" from "set to 0/false". */
    conf->enabled         = NGX_CONF_UNSET;
    conf->hydration       = NGX_CONF_UNSET;
    conf->max_buffer_size = NGX_CONF_UNSET;

    return conf;
}

/* ------------------------------------------------------------------ */
/* merge_loc_conf                                                     */
/*                                                                    */
/* Inherit unset values from the parent location.  Defaults:          */
/*   enabled         = 0 (off)                                        */
/*   app_name        = "" (empty — must be set when enabled)          */
/*   hydration       = 1 (on)                                        */
/*   script_nonce    = "" (no nonce)                                  */
/*   max_buffer_size = 0 (unlimited)                                  */
/* ------------------------------------------------------------------ */
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
/* BUFFERED content handler (baseline — kept for comparison).         */
/*                                                                    */
/* Calls nim_render_app to build the full HTML as a string, then      */
/* sends it as a single ngx_buf_t with Content-Length.  This is the   */
/* simpler path but involves an extra string copy.  NOT registered    */
/* by default — see postconfiguration.  To re-enable, swap the       */
/* handler pointer in ngx_http_isonim_postconfiguration.              */
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

    /* Ensure Nim runtime is initialized. */
    if (!nim_initialized) {
        nim_module_init();
        nim_initialized = 1;
    }

    /* Retrieve this location's config. */
    conf = ngx_http_get_module_loc_conf(r, ngx_http_isonim_module);

    if (conf == NULL || !conf->enabled) {
        return NGX_DECLINED;
    }

    /* Only handle GET and HEAD — other methods are not meaningful for SSR. */
    if (!(r->method & (NGX_HTTP_GET | NGX_HTTP_HEAD))) {
        return NGX_HTTP_NOT_ALLOWED;
    }

    /* Discard the request body — SSR does not consume it. */
    rc = ngx_http_discard_request_body(r);
    if (rc != NGX_OK) {
        return rc;
    }

    /* Call into Nim to render the app. */
    rc = nim_render_app(
        (const char *)conf->app_name.data,
        (int)conf->app_name.len,
        (int)conf->hydration,
        (const char *)conf->script_nonce.data,
        (int)conf->script_nonce.len,
        &html, &html_len);

    if (rc != NGX_OK || html == NULL) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    /* Set response headers. */
    r->headers_out.status = NGX_HTTP_OK;
    r->headers_out.content_length_n = html_len;
    r->headers_out.content_type_len = sizeof("text/html; charset=utf-8") - 1;
    ngx_str_set(&r->headers_out.content_type, "text/html; charset=utf-8");

    rc = ngx_http_send_header(r);
    if (rc == NGX_ERROR || rc > NGX_OK || r->header_only) {
        nim_free_html(html);
        return rc;
    }

    /* Create buffer with response body. */
    b = ngx_create_temp_buf(r->pool, html_len);
    if (b == NULL) {
        nim_free_html(html);
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    ngx_memcpy(b->pos, html, html_len);
    b->last = b->pos + html_len;
    b->last_buf = 1;
    b->memory = 1;

    nim_free_html(html);

    out.buf = b;
    out.next = NULL;

    return ngx_http_output_filter(r, &out);
}

/* ------------------------------------------------------------------ */
/* STREAMING content handler (production — registered by default).    */
/*                                                                    */
/* Sends headers then calls nim_render_streaming which writes HTML    */
/* directly to the nginx output chain through a faststreams           */
/* OutputStream (NginxOutputStream → flushCallback → ngx_buf_t →     */
/* ngx_http_output_filter).  No intermediate string allocation        */
/* beyond what the DSL produces.                                      */
/*                                                                    */
/* The isonim SSR code (renderToOutputStream) is backend-agnostic —  */
/* it writes to any faststreams OutputStream.  The nginx adapter      */
/* is wired in at the ngx-isonim level.                               */
/* ------------------------------------------------------------------ */
static ngx_int_t
ngx_http_isonim_streaming_handler(ngx_http_request_t *r)
{
    ngx_http_isonim_loc_conf_t *conf;
    ngx_int_t   rc;

    /* Ensure Nim runtime is initialized. */
    if (!nim_initialized) {
        nim_module_init();
        nim_initialized = 1;
    }

    /* Retrieve this location's config. */
    conf = ngx_http_get_module_loc_conf(r, ngx_http_isonim_module);

    if (conf == NULL || !conf->enabled) {
        return NGX_DECLINED;
    }

    /* Only handle GET and HEAD. */
    if (!(r->method & (NGX_HTTP_GET | NGX_HTTP_HEAD))) {
        return NGX_HTTP_NOT_ALLOWED;
    }

    /* Discard the request body. */
    rc = ngx_http_discard_request_body(r);
    if (rc != NGX_OK) {
        return rc;
    }

    /* Send response headers — chunked transfer, no Content-Length. */
    r->headers_out.status = NGX_HTTP_OK;
    r->headers_out.content_type_len = sizeof("text/html; charset=utf-8") - 1;
    ngx_str_set(&r->headers_out.content_type, "text/html; charset=utf-8");
    /* Set to -1 to indicate unknown length — nginx uses chunked transfer. */
    r->headers_out.content_length_n = -1;

    rc = ngx_http_send_header(r);
    if (rc == NGX_ERROR || rc > NGX_OK || r->header_only) {
        return rc;
    }

    /* Call Nim to stream render directly into the nginx output chain.
     * nim_render_streaming creates a NginxOutputStream wrapping (r, pool),
     * renders the app into it, and flush sends chunks via
     * ngx_http_output_filter. */
    rc = nim_render_streaming(
        (void *)r, (void *)r->pool,
        (const char *)conf->app_name.data,
        (int)conf->app_name.len,
        (int)conf->hydration,
        (const char *)conf->script_nonce.data,
        (int)conf->script_nonce.len);

    return rc;
}

/* ------------------------------------------------------------------ */
/* postconfiguration                                                  */
/*                                                                    */
/* Registers the content-phase handler.  Currently uses the streaming */
/* handler (faststreams path).  To switch to the buffered baseline    */
/* for comparison, change the assignment below to:                    */
/*   *h = ngx_http_isonim_handler;                                   */
/* ------------------------------------------------------------------ */
static ngx_int_t
ngx_http_isonim_postconfiguration(ngx_conf_t *cf)
{
    ngx_http_handler_pt        *h;
    ngx_http_core_main_conf_t  *cmcf;

    cmcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_core_module);

    h = ngx_array_push(&cmcf->phases[NGX_HTTP_CONTENT_PHASE].handlers);
    if (h == NULL) {
        return NGX_ERROR;
    }

    /* Streaming handler is under investigation (hangs on first request).
     * Using buffered handler which works correctly.
     * To re-enable streaming, change to: ngx_http_isonim_streaming_handler */
    *h = ngx_http_isonim_handler;

    return NGX_OK;
}
