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
/* Nim handler — defined in handler.nim, exported as a C symbol.      */
/* ------------------------------------------------------------------ */
extern ngx_int_t nim_handle_request(ngx_http_request_t *r);

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
/* Content handler.                                                   */
/*                                                                    */
/* Registered in the NGX_HTTP_CONTENT_PHASE.  Runs for every request  */
/* that reaches a location where isonim_ssr is configured.  If the    */
/* module is disabled for this location we return NGX_DECLINED to let */
/* the next handler in the phase chain take over.  Otherwise we       */
/* delegate to the Nim handler which performs the actual SSR.          */
/* ------------------------------------------------------------------ */
static ngx_int_t
ngx_http_isonim_handler(ngx_http_request_t *r)
{
    ngx_http_isonim_loc_conf_t *conf;

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
    ngx_int_t rc = ngx_http_discard_request_body(r);
    if (rc != NGX_OK) {
        return rc;
    }

    /* Set the Content-Type header before delegating to Nim.  The Nim
     * handler may override this, but a sensible default avoids sending
     * an empty Content-Type if the handler returns early. */
    r->headers_out.content_type_len = sizeof("text/html") - 1;
    ngx_str_set(&r->headers_out.content_type, "text/html");

    /* Delegate to the Nim-compiled handler. */
    return nim_handle_request(r);
}

/* ------------------------------------------------------------------ */
/* postconfiguration                                                  */
/*                                                                    */
/* Called after nginx has finished parsing the config.  We push our   */
/* handler onto the content phase array so that it runs for matching  */
/* locations.                                                         */
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

    *h = ngx_http_isonim_handler;

    return NGX_OK;
}
