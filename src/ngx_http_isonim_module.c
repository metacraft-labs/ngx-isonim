/*
 * ngx_http_isonim_module.c
 *
 * nginx module registration boilerplate for ngx-isonim.
 * Defines the module structure, directives, and hooks into
 * the Nim-compiled handler via extern declaration.
 *
 * This is the C entry point that nginx loads as a dynamic module.
 * The actual request handling is done in handler.nim (compiled to C).
 */

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>

/* Forward declaration of the Nim handler */
extern ngx_int_t nimHandleRequest(ngx_http_request_t *r);

/* Per-location configuration */
typedef struct {
    ngx_flag_t  enabled;
    ngx_str_t   app_name;
    ngx_flag_t  hydration;
    ngx_str_t   script_nonce;
    ngx_int_t   max_buffer_size;
} ngx_http_isonim_loc_conf_t;

/* Forward declarations */
static void *ngx_http_isonim_create_loc_conf(ngx_conf_t *cf);
static char *ngx_http_isonim_merge_loc_conf(ngx_conf_t *cf, void *parent, void *child);
static ngx_int_t ngx_http_isonim_postconfiguration(ngx_conf_t *cf);
static ngx_int_t ngx_http_isonim_handler(ngx_http_request_t *r);

/* Directives */
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

/* Module context */
static ngx_http_module_t ngx_http_isonim_module_ctx = {
    NULL,                                   /* preconfiguration */
    ngx_http_isonim_postconfiguration,      /* postconfiguration */
    NULL,                                   /* create main configuration */
    NULL,                                   /* init main configuration */
    NULL,                                   /* create server configuration */
    NULL,                                   /* merge server configuration */
    ngx_http_isonim_create_loc_conf,        /* create location configuration */
    ngx_http_isonim_merge_loc_conf          /* merge location configuration */
};

/* Module definition */
ngx_module_t ngx_http_isonim_module = {
    NGX_MODULE_V1,
    &ngx_http_isonim_module_ctx,    /* module context */
    ngx_http_isonim_commands,       /* module directives */
    NGX_HTTP_MODULE,                /* module type */
    NULL,                           /* init master */
    NULL,                           /* init module */
    NULL,                           /* init process */
    NULL,                           /* init thread */
    NULL,                           /* exit thread */
    NULL,                           /* exit process */
    NULL,                           /* exit master */
    NGX_MODULE_V1_PADDING
};

static void *
ngx_http_isonim_create_loc_conf(ngx_conf_t *cf)
{
    ngx_http_isonim_loc_conf_t *conf;

    conf = ngx_pcalloc(cf->pool, sizeof(ngx_http_isonim_loc_conf_t));
    if (conf == NULL) {
        return NULL;
    }

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

static ngx_int_t
ngx_http_isonim_handler(ngx_http_request_t *r)
{
    ngx_http_isonim_loc_conf_t *conf;

    conf = ngx_http_get_module_loc_conf(r, ngx_http_isonim_module);

    if (!conf->enabled) {
        return NGX_DECLINED;
    }

    /* Delegate to the Nim handler */
    return nimHandleRequest(r);
}

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
