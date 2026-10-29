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
 *     manipulate from C;
 *   - application shared-memory zones (the isonim_shm_zone directive, in
 *     the http block): each an nginx shared-memory zone with a slab pool,
 *     the reload rule that decides whether a new configuration's zone keeps
 *     the old contents, and the helpers shm_table.nim's operations call
 *     (the zone lookup, the pool's mutex, the slab allocator);
 *   - Interior-opened Boundary channels (the isonim_boundary* directives,
 *     in a server block): the peer-class check on the verified client
 *     certificate, the long-lived HTTP/2 stream of each channel (its
 *     request body read unbuffered, its response body written frame by
 *     frame), the worker's channel list, the per-slot channel counts in a
 *     small shared zone, and the helpers boundary.nim calls (send, close,
 *     the hold that keeps an exiting worker alive while calls are in
 *     flight).
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

#include "ngx_http_isonim_shm.h"

#if (NGX_HTTP_SSL)
#include <openssl/x509v3.h>
#endif

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
/* The module's per-request ctx is one of two kinds; both structs begin
 * with `kind`, so the request body filter can tell them apart. */
#define NGX_HTTP_ISONIM_CTX_RPC       1
#define NGX_HTTP_ISONIM_CTX_BOUNDARY  2

typedef struct {
    ngx_uint_t           kind;       /* NGX_HTTP_ISONIM_CTX_RPC             */
    ngx_http_request_t  *request;
    ngx_event_t          timeout;    /* isonim_rpc_timeout                  */
    void                *nim_state;  /* rpc.nim's RpcState (GC_ref'd)       */
    size_t               body_limit; /* isonim_rpc_max_body_size; 0 = none  */
    off_t                body_read;  /* body bytes seen by the body filter  */
    /* The response body's buffers handed to nginx, oldest first.  Their
     * bytes live outside the request pool (ngx_alloc) and are freed as
     * soon as nginx has written them (ngx_http_isonim_rpc_reclaim), so a
     * response streamed for hours holds only what the client has not read
     * yet (spec/isonim-nginx.md, "Backpressure"). */
    ngx_chain_t         *out_busy;
    ngx_chain_t        **out_busy_tail;
    ngx_chain_t         *out_free;   /* emptied links and bufs, reused       */
} ngx_http_isonim_rpc_ctx_t;

/* rpc.nim: starts the request (the body is read).  Nim binds its state to
 * ctx (ngx_http_isonim_rpc_bind) before anything can finalize it. */
extern void nim_handle_rpc(
    ngx_http_request_t *r, ngx_http_isonim_rpc_ctx_t *ctx,
    ngx_http_isonim_request_view_t *view, size_t view_size,
    const u_char *body, size_t body_len,
    const u_char *app_name, size_t app_name_len,
    ngx_int_t hydration, size_t max_buffer_size);
/* rpc.nim: isonim_rpc_timeout expired. */
extern void nim_rpc_timeout(void *nim_state);
/* rpc.nim: the request pool is being destroyed; drop the state. */
extern void nim_rpc_released(void *nim_state);
/* async_loop.nim: run what is ready on Nim's event loop. */
extern void nim_async_pump(void);

/* boundary.nim: a channel was opened (the node's 200 is sent); returns
 * Nim's state for it (GC_ref'd until nim_boundary_closed). */
extern void *nim_boundary_open(void *channel,
    const u_char *node_id, size_t node_id_len,
    const u_char *peer_node, size_t peer_node_len,
    ngx_uint_t worker_slot, ngx_uint_t workers, ngx_uint_t channels_in_slot,
    ngx_uint_t min_channels, size_t max_frame);
/* boundary.nim: bytes of the peer's request body (frames, possibly split). */
extern void nim_boundary_data(void *nim_state, const u_char *data, size_t len);
/* boundary.nim: the channel is gone; fail its calls, drop the state. */
extern void nim_boundary_closed(void *nim_state);

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

/* ------------------------------------------------------------------ */
/* Main (http) configuration: the application shared-memory zones.     */
/* ------------------------------------------------------------------ */

/* One isonim_shm_zone.  Allocated on its own (the zones array holds
 * pointers), because the shm zone's `data` points at it. */
typedef struct {
    ngx_str_t        name;
    size_t           size;
    size_t           max_value;
    ngx_shm_zone_t  *shm_zone;
} ngx_http_isonim_shm_conf_t;

typedef struct {
    ngx_array_t      zones;      /* of ngx_http_isonim_shm_conf_t *        */
    ngx_shm_zone_t  *boundary_zone;  /* per-slot channel counts, or NULL   */
} ngx_http_isonim_main_conf_t;

/* ------------------------------------------------------------------ */
/* Server configuration: Interior-opened Boundary channels.            */
/* spec/isonim-nginx.md, "Interior-Opened Boundary Channels".          */
/* ------------------------------------------------------------------ */

typedef struct {
    ngx_flag_t   enabled;        /* isonim_boundary                       */
    ngx_str_t    peer_class;     /* isonim_boundary_peer_class            */
    size_t       max_frame;      /* isonim_boundary_max_frame             */
    ngx_uint_t   min_channels;   /* isonim_boundary_min_channels          */
} ngx_http_isonim_srv_conf_t;

#define NGX_HTTP_ISONIM_BOUNDARY_DEFAULT_FRAME     (1024 * 1024)
#define NGX_HTTP_ISONIM_BOUNDARY_MIN_FRAME         1024
#define NGX_HTTP_ISONIM_BOUNDARY_MAX_FRAME         (64 * 1024 * 1024)
#define NGX_HTTP_ISONIM_BOUNDARY_DEFAULT_CHANNELS  2
#define NGX_HTTP_ISONIM_BOUNDARY_MAX_CHANNELS      64
#define NGX_HTTP_ISONIM_BOUNDARY_CLASS_MAX         64
/* The per-slot counts: one ngx_atomic_t per possible worker. */
#define NGX_HTTP_ISONIM_BOUNDARY_MAX_SLOTS         NGX_MAX_PROCESSES

/* spec/isonim-nginx.md, "Shared-Memory Zones for Applications". */
#define NGX_HTTP_ISONIM_SHM_NAME_MAX       64
#define NGX_HTTP_ISONIM_SHM_MIN_SIZE       (64 * 1024)
#define NGX_HTTP_ISONIM_SHM_MAX_SIZE       ((off_t) 4 * 1024 * 1024 * 1024)
#define NGX_HTTP_ISONIM_SHM_DEFAULT_VALUE  4096

/* Forward declarations */
static void      *ngx_http_isonim_create_main_conf(ngx_conf_t *cf);
static char      *ngx_http_isonim_shm_zone(ngx_conf_t *cf,
                      ngx_command_t *cmd, void *conf);
static void      *ngx_http_isonim_create_srv_conf(ngx_conf_t *cf);
static char      *ngx_http_isonim_merge_srv_conf(ngx_conf_t *cf,
                      void *parent, void *child);
static char      *ngx_http_isonim_boundary(ngx_conf_t *cf,
                      ngx_command_t *cmd, void *conf);
static ngx_int_t  ngx_http_isonim_init_process(ngx_cycle_t *cycle);
static void      *ngx_http_isonim_create_loc_conf(ngx_conf_t *cf);
static char      *ngx_http_isonim_merge_loc_conf(ngx_conf_t *cf,
                      void *parent, void *child);
static ngx_int_t  ngx_http_isonim_postconfiguration(ngx_conf_t *cf);
static ngx_int_t  ngx_http_isonim_handler(ngx_http_request_t *r);
static void       ngx_http_isonim_exit_process(ngx_cycle_t *cycle);
static ngx_int_t  ngx_http_isonim_init_module(ngx_cycle_t *cycle);

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

    /* isonim_shm_zone <name> size=<size> [max_value=<size>]: a
     * shared-memory zone an application binds by name (shmTable). */
    { ngx_string("isonim_shm_zone"),
      NGX_HTTP_MAIN_CONF | NGX_CONF_TAKE23,
      ngx_http_isonim_shm_zone,
      NGX_HTTP_MAIN_CONF_OFFSET,
      0,
      NULL },

    /* isonim_boundary on: this server is a Boundary listener, where an
     * Interior peer opens channels (POST /_boundary/v1/channel over
     * HTTP/2).  nginx -t requires ssl_verify_client on and
     * isonim_boundary_peer_class. */
    { ngx_string("isonim_boundary"),
      NGX_HTTP_SRV_CONF | NGX_CONF_FLAG,
      ngx_http_isonim_boundary,
      NGX_HTTP_SRV_CONF_OFFSET,
      offsetof(ngx_http_isonim_srv_conf_t, enabled),
      NULL },

    /* The only workload class (the URI SAN's class segment) accepted. */
    { ngx_string("isonim_boundary_peer_class"),
      NGX_HTTP_SRV_CONF | NGX_CONF_TAKE1,
      ngx_conf_set_str_slot,
      NGX_HTTP_SRV_CONF_OFFSET,
      offsetof(ngx_http_isonim_srv_conf_t, peer_class),
      NULL },

    /* The largest frame either way (k/m suffixes); default 1m. */
    { ngx_string("isonim_boundary_max_frame"),
      NGX_HTTP_SRV_CONF | NGX_CONF_TAKE1,
      ngx_conf_set_size_slot,
      NGX_HTTP_SRV_CONF_OFFSET,
      offsetof(ngx_http_isonim_srv_conf_t, max_frame),
      NULL },

    /* The channels a peer should keep in every worker slot; default 2.
     * Reported to the peer in the node's handshake. */
    { ngx_string("isonim_boundary_min_channels"),
      NGX_HTTP_SRV_CONF | NGX_CONF_TAKE1,
      ngx_conf_set_num_slot,
      NGX_HTTP_SRV_CONF_OFFSET,
      offsetof(ngx_http_isonim_srv_conf_t, min_channels),
      NULL },

    ngx_null_command
};

/* ------------------------------------------------------------------ */
/* Module context                                                     */
/* ------------------------------------------------------------------ */

static ngx_http_module_t ngx_http_isonim_module_ctx = {
    NULL,
    ngx_http_isonim_postconfiguration,
    ngx_http_isonim_create_main_conf,
    NULL,
    ngx_http_isonim_create_srv_conf,
    ngx_http_isonim_merge_srv_conf,
    ngx_http_isonim_create_loc_conf,
    ngx_http_isonim_merge_loc_conf
};

ngx_module_t ngx_http_isonim_module = {
    NGX_MODULE_V1,
    &ngx_http_isonim_module_ctx,
    ngx_http_isonim_commands,
    NGX_HTTP_MODULE,
    NULL,                                  /* init master    */
    ngx_http_isonim_init_module,           /* init module    */
    ngx_http_isonim_init_process,          /* init process   */
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
/* A streamed isonim_rpc response: nginx's backpressure.              */
/*                                                                    */
/* An async app's flush passes its bytes down the output chain while  */
/* the request is still in progress (its handler is awaiting).  What  */
/* the socket does not take at once stays in the chain (r->out,       */
/* c->buffered: ngx_http_output_filter returned NGX_AGAIN).  Nothing  */
/* in nginx would send it before the request is finalized, so the     */
/* request's write event handler does, as the socket drains: the      */
/* event loop never waits for a slow client, and nginx holds the      */
/* unsent bytes.  send_timeout bounds a client that stops reading; a  */
/* failed send terminates the request, whose pool cleanup tells Nim   */
/* (nim_rpc_released), so the handler's next write raises.  Once the */
/* last buffer is sent, finalizing hands the rest to ngx_http_writer. */
/* ------------------------------------------------------------------ */

static ngx_int_t ngx_http_isonim_rpc_arm(ngx_http_request_t *r);
static ngx_http_isonim_rpc_ctx_t *ngx_http_isonim_rpc_ctx(ngx_http_request_t *r);

/* Frees the bytes of the response buffers nginx has written (they are
 * written, and emptied, in order); keeps their links for reuse. */
static void
ngx_http_isonim_rpc_reclaim(ngx_http_isonim_rpc_ctx_t *ctx)
{
    ngx_chain_t  *cl;

    while (ctx->out_busy != NULL && ngx_buf_size(ctx->out_busy->buf) == 0) {
        cl = ctx->out_busy;
        ctx->out_busy = cl->next;
        ngx_free(cl->buf->start);
        cl->buf->start = NULL;
        cl->next = ctx->out_free;
        ctx->out_free = cl;
    }
    if (ctx->out_busy == NULL) {
        ctx->out_busy_tail = &ctx->out_busy;
    }
}

/* Called from Nim: the flushed body bytes of an isonim_rpc response that
 * nginx has not written to the socket yet; 0 for any other request. */
size_t
ngx_http_isonim_rpc_unsent(ngx_http_request_t *r)
{
    ngx_http_isonim_rpc_ctx_t  *ctx;
    ngx_chain_t                *cl;
    size_t                      n = 0;

    ctx = ngx_http_isonim_rpc_ctx(r);
    if (ctx == NULL) {
        return 0;
    }
    ngx_http_isonim_rpc_reclaim(ctx);
    for (cl = ctx->out_busy; cl; cl = cl->next) {
        n += (size_t) ngx_buf_size(cl->buf);
    }
    return n;
}

static ngx_http_isonim_rpc_ctx_t *
ngx_http_isonim_rpc_ctx(ngx_http_request_t *r)
{
    ngx_http_isonim_rpc_ctx_t  *ctx;

    ctx = ngx_http_get_module_ctx(r, ngx_http_isonim_module);
    if (ctx == NULL || ctx->kind != NGX_HTTP_ISONIM_CTX_RPC
        || ctx->request != r)
    {
        return NULL;
    }
    return ctx;
}

static void
ngx_http_isonim_rpc_writer(ngx_http_request_t *r)
{
    ngx_int_t          rc;
    ngx_event_t       *wev;
    ngx_connection_t  *c;

    c = r->connection;
    wev = c->write;

    if (wev->timedout) {
        ngx_log_error(NGX_LOG_INFO, c->log, NGX_ETIMEDOUT,
                      "isonim: client timed out while a streamed response "
                      "was being sent");
        c->timedout = 1;
        ngx_http_finalize_request(r, NGX_HTTP_REQUEST_TIME_OUT);
        return;
    }

    if (wev->delayed || r->aio) {
        if (!wev->delayed) {
            (void) ngx_http_isonim_rpc_arm(r);
        }
        return;
    }

    rc = ngx_http_output_filter(r, NULL);
    if (ngx_http_isonim_rpc_ctx(r) != NULL) {
        ngx_http_isonim_rpc_reclaim(ngx_http_isonim_rpc_ctx(r));
    }
    if (rc == NGX_ERROR) {
        /* The client went away: terminate; the pool cleanup releases the
         * Nim state. */
        ngx_http_finalize_request(r, NGX_ERROR);
        return;
    }

    if (ngx_http_isonim_rpc_arm(r) != NGX_OK) {
        ngx_http_finalize_request(r, NGX_ERROR);
    }
}

/* Keeps the write event (and send_timeout) armed while nginx holds unsent
 * bytes of the request; disarms the timer once they are sent. */
static ngx_int_t
ngx_http_isonim_rpc_arm(ngx_http_request_t *r)
{
    ngx_event_t               *wev;
    ngx_connection_t          *c;
    ngx_http_core_loc_conf_t  *clcf;

    c = r->connection;
    wev = c->write;
    clcf = ngx_http_get_module_loc_conf(r, ngx_http_core_module);

    if (r->buffered || r->postponed || c->buffered) {
        if (!wev->delayed) {
            ngx_add_timer(wev, clcf->send_timeout);
        }
        return ngx_handle_write_event(wev, clcf->send_lowat);
    }
    if (wev->timer_set) {
        ngx_del_timer(wev);
    }
    return NGX_OK;
}

/* After a body send of an isonim_rpc request that did not end it: the
 * write handler above drains what nginx could not send. */
static void
ngx_http_isonim_rpc_hold(ngx_http_request_t *r)
{
    if (ngx_http_isonim_rpc_ctx(r) == NULL) {
        return;     /* an SSR location: its content handler finalizes */
    }
    r->write_event_handler = ngx_http_isonim_rpc_writer;
    if (ngx_http_isonim_rpc_arm(r) != NGX_OK) {
        ngx_log_error(NGX_LOG_ERR, r->connection->log, 0,
                      "isonim: cannot watch the connection for writing");
    }
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
    ngx_buf_t                  *b;
    ngx_chain_t                 out, *cl;
    ngx_int_t                   rc;
    ngx_http_isonim_rpc_ctx_t  *ctx;
    u_char                     *p;

    if (len == 0 && !flush && !last) return NGX_OK;

    ctx = ngx_http_isonim_rpc_ctx(r);
    if (len > 0 && ctx != NULL) {
        /* An isonim_rpc response: the bytes outside the request pool,
         * freed once written (ngx_http_isonim_rpc_reclaim). */
        p = ngx_alloc(len, r->connection->log);
        if (p == NULL) return NGX_ERROR;
        if (ctx->out_free != NULL) {
            cl = ctx->out_free;
            ctx->out_free = cl->next;
            b = cl->buf;
        } else {
            cl = ngx_alloc_chain_link(r->pool);
            b = ngx_calloc_buf(r->pool);
            if (cl == NULL || b == NULL) {
                ngx_free(p);
                return NGX_ERROR;
            }
            cl->buf = b;
        }
        ngx_memzero(b, sizeof(ngx_buf_t));
        ngx_memcpy(p, data, len);
        b->start = p;
        b->pos = p;
        b->last = p + len;
        b->end = p + len;
        b->temporary = 1;
        b->tag = (ngx_buf_tag_t) &ngx_http_isonim_send_body;
        cl->next = NULL;
        if (ctx->out_busy_tail == NULL) {
            ctx->out_busy_tail = &ctx->out_busy;
        }
        *ctx->out_busy_tail = cl;
        ctx->out_busy_tail = &cl->next;
    } else if (len > 0) {
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
    rc = ngx_http_output_filter(r, &out);
    if (ctx != NULL) {
        ngx_http_isonim_rpc_reclaim(ctx);
    }

    if (rc != NGX_ERROR && !last) {
        ngx_http_isonim_rpc_hold(r);
    }
    return rc;
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
static ngx_int_t ngx_http_isonim_boundary_handler(ngx_http_request_t *r,
    ngx_http_isonim_srv_conf_t *iscf);

static ngx_int_t
ngx_http_isonim_handler(ngx_http_request_t *r)
{
    ngx_http_isonim_loc_conf_t      *conf;
    ngx_http_isonim_request_view_t   view;
    ngx_int_t                        rc;

    ngx_http_isonim_srv_conf_t      *iscf;

    iscf = ngx_http_get_module_srv_conf(r, ngx_http_isonim_module);
    if (iscf != NULL && iscf->enabled) {
        ngx_http_isonim_init_nim();
        return ngx_http_isonim_boundary_handler(r, iscf);
    }

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
    ngx_connection_t           *c;

    ctx = ngx_http_get_module_ctx(r, ngx_http_isonim_module);
    if (ctx != NULL && ctx->kind == NGX_HTTP_ISONIM_CTX_RPC
        && ctx->timeout.timer_set)
    {
        ngx_del_timer(&ctx->timeout);
    }
    c = r->connection;
    ngx_http_finalize_request(r, rc);

    /* NGX_ERROR (a streamed response terminated after its headers) makes
     * nginx post a request that terminates this one, and only
     * ngx_http_request_handler runs posted requests.  Nim calls this from
     * the event loop's timer and descriptor events and from the
     * isonim_rpc_timeout timer, outside any request handler, so post the
     * connection's write event: nginx then runs the request handler,
     * which terminates the request on the event loop's next turn.  (Running
     * the posted requests here instead could free the request while a C
     * frame below still holds it, e.g. nim_handle_rpc's body handler.) */
    if (rc == NGX_ERROR && !c->destroyed) {
        ngx_post_event(c->write, &ngx_posted_events);
    }
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
    /* The request is over: the bytes nginx never wrote go with it. */
    while (ctx->out_busy != NULL) {
        ngx_free(ctx->out_busy->buf->start);
        ctx->out_busy->buf->start = NULL;
        ctx->out_busy = ctx->out_busy->next;
    }
    ctx->out_busy_tail = &ctx->out_busy;
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
                   conf->rpc_app.data, conf->rpc_app.len,
                   conf->hydration, conf->max_buffer_size);
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
    if (ctx != NULL && ctx->kind == NGX_HTTP_ISONIM_CTX_RPC
        && ctx->request == r && ctx->body_limit)
    {
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
    ctx->kind = NGX_HTTP_ISONIM_CTX_RPC;
    ctx->request = r;
    ctx->body_limit = conf->rpc_max_body_size;
    ctx->out_busy_tail = &ctx->out_busy;
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
/* Application shared-memory zones (isonim_shm_zone)                  */
/*                                                                    */
/* nginx creates shared memory only while it reads its configuration, */
/* before any worker exists, so a zone is declared in the http block  */
/* and an application binds it by name in a worker (shm_table.nim).   */
/* The zone's slab pool is set up by nginx (ngx_init_zone_pool); the  */
/* table's header is set up by the first worker that binds the zone,  */
/* under the pool's mutex, so the master never runs Nim code.         */
/* ------------------------------------------------------------------ */

static void *
ngx_http_isonim_create_main_conf(ngx_conf_t *cf)
{
    ngx_http_isonim_main_conf_t  *imcf;

    imcf = ngx_pcalloc(cf->pool, sizeof(ngx_http_isonim_main_conf_t));
    if (imcf == NULL) {
        return NULL;
    }
    if (ngx_array_init(&imcf->zones, cf->pool, 4,
                       sizeof(ngx_http_isonim_shm_conf_t *))
        != NGX_OK)
    {
        return NULL;
    }
    return imcf;
}

/* The zone's init callback, run by nginx in the master for every new
 * cycle.  `data` is the previous configuration's zone when there was one
 * of the same name; nginx has then either handed this zone the old
 * segment (same name, size and module, and the reload check below did not
 * set noreuse) or a fresh, zero-filled one.  Either way the slab pool is
 * ready; the table's header (pool->data) is the first binding worker's
 * to create, or survives from the old segment. */
static ngx_int_t
ngx_http_isonim_shm_init(ngx_shm_zone_t *shm_zone, void *data)
{
    ngx_http_isonim_shm_conf_t  *zc = shm_zone->data;
    ngx_slab_pool_t             *sp;
    size_t                       len;

    sp = (ngx_slab_pool_t *) shm_zone->shm.addr;

    /* A store that finds no room evicts and retries (shm_table.nim); the
     * slab allocator must not log every failed attempt. */
    sp->log_nomem = 0;

    if (sp->log_ctx == NULL) {
        /* A fresh segment: name the zone in the slab allocator's own
         * messages, as nginx's modules do. */
        len = sizeof(" in isonim_shm_zone \"\"") + zc->name.len;
        sp->log_ctx = ngx_slab_alloc(sp, len);
        if (sp->log_ctx == NULL) {
            return NGX_ERROR;
        }
        ngx_sprintf(sp->log_ctx, " in isonim_shm_zone \"%V\"%Z", &zc->name);
    }
    return NGX_OK;
}

/* Reload rule (spec/isonim-nginx.md, "Reload").  nginx itself hands a new
 * configuration's zone the old segment when the name, the size and the
 * owning module are unchanged.  The table may keep its contents only when
 * its max_value and the module's zone layout are unchanged too: otherwise
 * the new zone is marked noreuse, so the new workers get a fresh segment
 * (the old workers keep theirs until they exit).  The old zone is marked
 * too, so that the master unmaps it instead of keeping it alive for
 * nothing, but only in init_module (ngx_http_isonim_init_module), once the
 * new cycle has been set up: this configuration may still fail, and a mark
 * on the old cycle's zone survives a failed reload, so the next reload
 * that reuses the segment would have the master unmap it from under its
 * new workers.
 *
 * Runs in the master while it reads the new configuration; the old
 * segment is mapped there at the same address.  Its header's magic,
 * layout and max_value are written once, before pool->data is set
 * (shm_table.nim), so reading them without the lock is safe. */
static void
ngx_http_isonim_shm_check_reuse(ngx_conf_t *cf, ngx_http_isonim_shm_conf_t *zc,
    ngx_shm_zone_t *shm_zone)
{
    ngx_uint_t                     i;
    ngx_cycle_t                   *old_cycle;
    ngx_list_part_t               *part;
    ngx_shm_zone_t                *oshm;
    ngx_slab_pool_t               *sp;
    ngx_http_isonim_shm_header_t  *hdr;

    old_cycle = cf->cycle->old_cycle;
    if (old_cycle == NULL || old_cycle->shared_memory.part.elts == NULL) {
        return;          /* the first start, or nginx -t */
    }

    part = &old_cycle->shared_memory.part;
    oshm = part->elts;

    for (i = 0; /* void */ ; i++) {

        if (i >= part->nelts) {
            if (part->next == NULL) {
                return;
            }
            part = part->next;
            oshm = part->elts;
            i = 0;
        }

        if (oshm[i].tag != &ngx_http_isonim_module
            || oshm[i].shm.name.len != zc->name.len
            || ngx_strncmp(oshm[i].shm.name.data, zc->name.data,
                           zc->name.len) != 0)
        {
            continue;
        }

        if (oshm[i].shm.size != zc->size || oshm[i].shm.addr == NULL) {
            return;      /* nginx gives the new zone a fresh segment */
        }

        sp = (ngx_slab_pool_t *) oshm[i].shm.addr;
        hdr = sp->data;
        if (hdr == NULL) {
            return;      /* never bound: an empty table either way */
        }

        if (hdr->magic != NGX_HTTP_ISONIM_SHM_MAGIC
            || hdr->layout != NGX_HTTP_ISONIM_SHM_LAYOUT
            || hdr->max_value != (uint64_t) zc->max_value)
        {
            ngx_conf_log_error(NGX_LOG_NOTICE, cf, 0,
                "isonim_shm_zone \"%V\" starts empty: its max_value or the "
                "module's zone layout changed", &zc->name);
            /* Never the old zone here: see above and init_module. */
            shm_zone->noreuse = 1;
        }
        return;
    }
}

/* Marks the old cycle's zone of the same name as `shm_zone` noreuse, so
 * that the master unmaps it (ngx_init_cycle frees an old zone marked
 * noreuse).  For init_module, below. */
static void
ngx_http_isonim_shm_release_old(ngx_cycle_t *old_cycle,
    ngx_shm_zone_t *shm_zone)
{
    ngx_uint_t        i;
    ngx_list_part_t  *part;
    ngx_shm_zone_t   *oshm;

    if (old_cycle == NULL || old_cycle->shared_memory.part.elts == NULL) {
        return;
    }

    part = &old_cycle->shared_memory.part;
    oshm = part->elts;

    for (i = 0; /* void */ ; i++) {

        if (i >= part->nelts) {
            if (part->next == NULL) {
                return;
            }
            part = part->next;
            oshm = part->elts;
            i = 0;
        }

        if (oshm[i].tag == &ngx_http_isonim_module
            && oshm[i].shm.name.len == shm_zone->shm.name.len
            && ngx_strncmp(oshm[i].shm.name.data, shm_zone->shm.name.data,
                           shm_zone->shm.name.len) == 0)
        {
            oshm[i].noreuse = 1;
            return;
        }
    }
}

/* init_module: runs in the master once the new cycle's shared memory is
 * set up and its listening sockets are open, just before nginx frees the
 * old cycle's segments that the new one does not reuse.  It runs only when
 * the new configuration has been accepted: a reload that fails earlier
 * (ngx_init_cycle's `failed:` path) never reaches it.
 *
 * For each new zone that the reload check marked noreuse (so that nginx
 * gave it a fresh segment):
 *
 *   - the old cycle's zone of that name is marked noreuse now, so that the
 *     master unmaps the segment the new zone does not use.  Marking it
 *     while the configuration is read instead would let a reload that
 *     then fails leave the mark on the running cycle's zone, and the next
 *     reload, reusing that segment, would have the master unmap it from
 *     under its new workers;
 *   - the new zone's own mark is cleared: at the next reload this cycle is
 *     the old one, and nginx frees an old zone marked noreuse even when the
 *     new configuration reuses it.  (Clearing it in the zone's init
 *     callback instead would keep a failed reload from freeing the fresh
 *     segment.) */
static ngx_int_t
ngx_http_isonim_init_module(ngx_cycle_t *cycle)
{
    ngx_uint_t        i;
    ngx_list_part_t  *part;
    ngx_shm_zone_t   *shm_zone;

    part = &cycle->shared_memory.part;
    shm_zone = part->elts;

    for (i = 0; /* void */ ; i++) {

        if (i >= part->nelts) {
            if (part->next == NULL) {
                break;
            }
            part = part->next;
            shm_zone = part->elts;
            i = 0;
        }

        if (shm_zone[i].tag == &ngx_http_isonim_module
            && shm_zone[i].noreuse)
        {
            ngx_http_isonim_shm_release_old(cycle->old_cycle, &shm_zone[i]);
            shm_zone[i].noreuse = 0;
        }
    }
    return NGX_OK;
}

/* Parses one size= or max_value= value: nginx sizes with k, m or g. */
static off_t
ngx_http_isonim_shm_parse_size(u_char *p, size_t len)
{
    ngx_str_t  s;

    s.data = p;
    s.len = len;
    return ngx_parse_offset(&s);
}

/* isonim_shm_zone <name> size=<size> [max_value=<size>] */
static char *
ngx_http_isonim_shm_zone(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ngx_http_isonim_main_conf_t   *imcf = conf;
    ngx_http_isonim_shm_conf_t    *zc, **zp, **existing;
    ngx_shm_zone_t                *shm_zone;
    ngx_str_t                     *value, name;
    ngx_uint_t                     i;
    off_t                          size, max_value;
    u_char                         c;

    value = cf->args->elts;
    name = value[1];

    if (name.len == 0 || name.len > NGX_HTTP_ISONIM_SHM_NAME_MAX) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
            "isonim_shm_zone name \"%V\" must be 1 to %d characters",
            &name, NGX_HTTP_ISONIM_SHM_NAME_MAX);
        return NGX_CONF_ERROR;
    }
    for (i = 0; i < name.len; i++) {
        c = name.data[i];
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')) {
            ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                "isonim_shm_zone name \"%V\" may hold only [a-z0-9_]", &name);
            return NGX_CONF_ERROR;
        }
    }

    size = 0;
    max_value = NGX_HTTP_ISONIM_SHM_DEFAULT_VALUE;

    for (i = 2; i < cf->args->nelts; i++) {
        if (value[i].len > 5 && ngx_strncmp(value[i].data, "size=", 5) == 0) {
            size = ngx_http_isonim_shm_parse_size(value[i].data + 5,
                                                  value[i].len - 5);
            if (size == NGX_ERROR) {
                goto invalid;
            }
            continue;
        }
        if (value[i].len > 10
            && ngx_strncmp(value[i].data, "max_value=", 10) == 0)
        {
            max_value = ngx_http_isonim_shm_parse_size(value[i].data + 10,
                                                       value[i].len - 10);
            if (max_value == NGX_ERROR) {
                goto invalid;
            }
            continue;
        }
        goto invalid;
    }

    if (size == 0) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
            "isonim_shm_zone \"%V\" requires size=", &name);
        return NGX_CONF_ERROR;
    }
    if (size < NGX_HTTP_ISONIM_SHM_MIN_SIZE
        || size > NGX_HTTP_ISONIM_SHM_MAX_SIZE)
    {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
            "isonim_shm_zone \"%V\": size=%O is outside 64k to 4g",
            &name, size);
        return NGX_CONF_ERROR;
    }
    if (max_value < 1 || max_value > size / 4) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
            "isonim_shm_zone \"%V\": max_value=%O must be at least 1 and at "
            "most a quarter of size= (%O)", &name, max_value, size / 4);
        return NGX_CONF_ERROR;
    }

    existing = imcf->zones.elts;
    for (i = 0; i < imcf->zones.nelts; i++) {
        if (existing[i]->name.len == name.len
            && ngx_strncmp(existing[i]->name.data, name.data, name.len) == 0)
        {
            ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                "isonim_shm_zone \"%V\" is declared twice", &name);
            return NGX_CONF_ERROR;
        }
    }

    zc = ngx_pcalloc(cf->pool, sizeof(ngx_http_isonim_shm_conf_t));
    zp = ngx_array_push(&imcf->zones);
    if (zc == NULL || zp == NULL) {
        return NGX_CONF_ERROR;
    }
    zc->name = name;
    zc->size = (size_t) size;
    zc->max_value = (size_t) max_value;

    /* Another module's zone of the same name makes this fail, with
     * nginx's own message. */
    shm_zone = ngx_shared_memory_add(cf, &name, zc->size,
                                     &ngx_http_isonim_module);
    if (shm_zone == NULL) {
        return NGX_CONF_ERROR;
    }
    shm_zone->init = ngx_http_isonim_shm_init;
    shm_zone->data = zc;
    zc->shm_zone = shm_zone;
    *zp = zc;

    ngx_http_isonim_shm_check_reuse(cf, zc, shm_zone);
    return NGX_CONF_OK;

invalid:
    ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
        "invalid isonim_shm_zone parameter \"%V\"", &value[i]);
    return NGX_CONF_ERROR;
}

/* --- Helpers shm_table.nim calls (in a worker) ---------------------- */

/* Looks up the zone this configuration declares as `name`.  Returns
 * NGX_OK and fills *info, or NGX_DECLINED when there is none. */
ngx_int_t
ngx_http_isonim_shm_find(const u_char *name, size_t len,
    ngx_http_isonim_shm_info_t *info)
{
    ngx_uint_t                    i;
    ngx_slab_pool_t              *sp;
    ngx_http_isonim_main_conf_t  *imcf;
    ngx_http_isonim_shm_conf_t  **zones, *zc;

    imcf = ngx_http_cycle_get_module_main_conf((ngx_cycle_t *) ngx_cycle,
                                               ngx_http_isonim_module);
    if (imcf == NULL) {
        return NGX_DECLINED;
    }
    zones = imcf->zones.elts;
    for (i = 0; i < imcf->zones.nelts; i++) {
        zc = zones[i];
        if (zc->name.len != len || ngx_memcmp(zc->name.data, name, len) != 0) {
            continue;
        }
        sp = (ngx_slab_pool_t *) zc->shm_zone->shm.addr;  /* the zone itself */
        info->pool = sp;
        info->data = &sp->data;
        info->size = zc->size;
        info->max_value = zc->max_value;
        return NGX_OK;
    }
    return NGX_DECLINED;
}

/* The zone's lock: the slab pool's own mutex, which the nginx master
 * releases when a worker dies holding it (ngx_unlock_mutexes). */
static ngx_shmtx_t *
ngx_http_isonim_shm_mutex(ngx_slab_pool_t *sp)
{
    return &sp->mutex;
}

/* Takes the zone's lock.  Returns 1 when another process held it, so the
 * caller had to wait (stats: lock waits), else 0. */
ngx_int_t
ngx_http_isonim_shm_lock(void *pool)
{
    ngx_shmtx_t  *mtx = ngx_http_isonim_shm_mutex(pool);

    if (ngx_shmtx_trylock(mtx)) {
        return 0;
    }
    ngx_shmtx_lock(mtx);
    return 1;
}

void
ngx_http_isonim_shm_unlock(void *pool)
{
    ngx_shmtx_unlock(ngx_http_isonim_shm_mutex(pool));
}

/* The slab allocator, with the zone's lock held.  NULL when it has no
 * room for `size` bytes. */
void *
ngx_http_isonim_shm_alloc(void *pool, size_t size)
{
    return ngx_slab_alloc_locked(pool, size);
}

void
ngx_http_isonim_shm_free(void *pool, void *p)
{
    ngx_slab_free_locked(pool, p);
}

/* The pool's page capacity and its free pages, in bytes. */
void
ngx_http_isonim_shm_pages(void *pool, uint64_t *total, uint64_t *free_bytes)
{
    ngx_slab_pool_t  *sp = pool;

    *total = (uint64_t) (sp->last - sp->pages) * ngx_pagesize;
    *free_bytes = (uint64_t) sp->pfree * ngx_pagesize;
}

/* ------------------------------------------------------------------ */
/* Interior-opened Boundary channels (isonim_boundary)                */
/*                                                                    */
/* spec/isonim-nginx.md, "Interior-Opened Boundary Channels".  An     */
/* Interior peer (the forum's write executor) opens every connection  */
/* to the node's Boundary listener and sends POST                     */
/* /_boundary/v1/channel over HTTP/2.  After the peer-class check on  */
/* its verified certificate the node answers 200 at once and keeps    */
/* both bodies open: the node's frames travel on the response body,   */
/* the peer's on the request body, which is read unbuffered           */
/* (r->request_body_no_buffering; nginx's HTTP/2 code then hands the  */
/* bytes over as they arrive, under the stream's flow control).       */
/*                                                                    */
/* A connection, and so a channel, belongs to the worker that         */
/* accepted it; the listener uses reuseport so that the peer can      */
/* reach every worker.  This file owns the stream (its reading,       */
/* writing, timers and end); boundary.nim owns the frames, the        */
/* handshakes and the calls, and sees the worker's channels as a      */
/* pool.  Nothing is ever written to disk: the body is never          */
/* buffered to a temporary file, and a frame is handed to nginx only  */
/* when a channel exists to carry it.                                 */
/* ------------------------------------------------------------------ */

#define NGX_HTTP_ISONIM_BOUNDARY_PATH  "/_boundary/v1/channel"
#define NGX_HTTP_ISONIM_SPIFFE_PREFIX  "spiffe://isonim-platform/app/"

/* One channel: the module ctx of its request, in the request pool. */
typedef struct {
    ngx_uint_t           kind;          /* NGX_HTTP_ISONIM_CTX_BOUNDARY    */
    ngx_http_request_t  *request;
    ngx_queue_t          queue;         /* the worker's channels           */
    void                *nim_state;     /* boundary.nim's channel          */
    ngx_str_t            node_id;       /* from the node's own certificate */
    ngx_str_t            peer_node;     /* from the peer's certificate     */
    ngx_http_isonim_srv_conf_t  *conf;
    time_t               peer_not_after;
    time_t               own_not_after; /* the node's own certificate's,
                                           the one this connection's TLS
                                           handshake presented            */
    ngx_event_t          expiry;        /* the earlier of the two notAfters */
    ngx_event_t          close_ev;      /* a close asked for (posted)      */
    ngx_chain_t         *busy;          /* frames handed to nginx, in
                                           order; their bytes are ngx_alloc'd
                                           and freed once written          */
    ngx_chain_t        **busy_tail;
    ngx_chain_t         *free;          /* links and bufs for reuse        */
    unsigned             attached:1;    /* counted in the worker's pool    */
    unsigned             finished:1;    /* finalized, or being finalized   */
} ngx_http_isonim_bch_t;

/* The worker's channels (attached ones), and their count. */
static ngx_queue_t   ngx_http_isonim_boundary_channels;
static ngx_uint_t    ngx_http_isonim_boundary_nchannels;
static ngx_uint_t    ngx_http_isonim_boundary_inited;

/* Keeps an exiting worker (reload, graceful stop) alive while
 * boundary.nim has calls in flight: a worker exits once only cancelable
 * timers are left, and a channel has no timer of its own. */
static ngx_event_t   ngx_http_isonim_boundary_hold_ev;
static ngx_flag_t    ngx_http_isonim_boundary_holding;
#define NGX_HTTP_ISONIM_BOUNDARY_HOLD_MS  1000

/* The tag of the per-slot counts zone: its own, so that the
 * isonim_shm_zone reload handling (init_module) never touches it. */
static ngx_uint_t    ngx_http_isonim_boundary_zone_tag;

static void ngx_http_isonim_boundary_read(ngx_http_request_t *r);
void ngx_http_isonim_boundary_close(void *channel);
static void ngx_http_isonim_boundary_write(ngx_http_request_t *r);
static void ngx_http_isonim_boundary_finish(ngx_http_isonim_bch_t *ch,
    ngx_int_t rc);

/* --- Configuration ------------------------------------------------- */

static void *
ngx_http_isonim_create_srv_conf(ngx_conf_t *cf)
{
    ngx_http_isonim_srv_conf_t  *conf;

    conf = ngx_pcalloc(cf->pool, sizeof(ngx_http_isonim_srv_conf_t));
    if (conf == NULL) {
        return NULL;
    }
    conf->enabled = NGX_CONF_UNSET;
    conf->max_frame = NGX_CONF_UNSET_SIZE;
    conf->min_channels = NGX_CONF_UNSET_UINT;
    return conf;
}

static char *
ngx_http_isonim_merge_srv_conf(ngx_conf_t *cf, void *parent, void *child)
{
    ngx_http_isonim_srv_conf_t  *prev = parent;
    ngx_http_isonim_srv_conf_t  *conf = child;
    ngx_uint_t                   i;
    u_char                       c;

    ngx_conf_merge_value(conf->enabled, prev->enabled, 0);
    ngx_conf_merge_str_value(conf->peer_class, prev->peer_class, "");
    ngx_conf_merge_size_value(conf->max_frame, prev->max_frame,
                              NGX_HTTP_ISONIM_BOUNDARY_DEFAULT_FRAME);
    ngx_conf_merge_uint_value(conf->min_channels, prev->min_channels,
                              NGX_HTTP_ISONIM_BOUNDARY_DEFAULT_CHANNELS);

    if (!conf->enabled) {
        return NGX_CONF_OK;
    }

#if (NGX_HTTP_SSL)
    {
        ngx_http_ssl_srv_conf_t  *sscf;

        /* ngx_http_ssl_module is compiled into nginx, so its server
         * configuration is merged before this dynamic module's. */
        sscf = ngx_http_conf_get_module_srv_conf(cf, ngx_http_ssl_module);
        if (sscf == NULL || sscf->verify != 1) {
            ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                "\"isonim_boundary on\" requires \"ssl_verify_client on\" "
                "(against the app's workload CA) in the same server");
            return NGX_CONF_ERROR;
        }
    }
#else
    ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
        "\"isonim_boundary\" requires nginx built with ngx_http_ssl_module");
    return NGX_CONF_ERROR;
#endif

    if (conf->peer_class.len == 0) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
            "\"isonim_boundary on\" requires \"isonim_boundary_peer_class\"");
        return NGX_CONF_ERROR;
    }
    if (conf->peer_class.len > NGX_HTTP_ISONIM_BOUNDARY_CLASS_MAX) {
        goto bad_class;
    }
    for (i = 0; i < conf->peer_class.len; i++) {
        c = conf->peer_class.data[i];
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
              || c == '_' || c == '-'))
        {
            goto bad_class;
        }
    }

    if (conf->max_frame < NGX_HTTP_ISONIM_BOUNDARY_MIN_FRAME
        || conf->max_frame > NGX_HTTP_ISONIM_BOUNDARY_MAX_FRAME)
    {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
            "\"isonim_boundary_max_frame\" %uz is outside 1k to 64m",
            conf->max_frame);
        return NGX_CONF_ERROR;
    }
    if (conf->min_channels < 1
        || conf->min_channels > NGX_HTTP_ISONIM_BOUNDARY_MAX_CHANNELS)
    {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
            "\"isonim_boundary_min_channels\" %ui is outside 1 to %d",
            conf->min_channels, NGX_HTTP_ISONIM_BOUNDARY_MAX_CHANNELS);
        return NGX_CONF_ERROR;
    }
    return NGX_CONF_OK;

bad_class:
    ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
        "\"isonim_boundary_peer_class\" \"%V\" must be 1 to %d characters "
        "of [a-z0-9_-]", &conf->peer_class,
        NGX_HTTP_ISONIM_BOUNDARY_CLASS_MAX);
    return NGX_CONF_ERROR;
}

/* The per-slot counts zone's init: the counts live in the slab pool nginx
 * set up.  The zone is created noreuse, so every configuration cycle gets
 * a fresh one (old workers keep counting into theirs until they exit). */
static ngx_int_t
ngx_http_isonim_boundary_zone_init(ngx_shm_zone_t *shm_zone, void *data)
{
    ngx_slab_pool_t  *sp = (ngx_slab_pool_t *) shm_zone->shm.addr;
    size_t            size;

    size = sizeof(ngx_atomic_t) * NGX_HTTP_ISONIM_BOUNDARY_MAX_SLOTS;
    sp->data = ngx_slab_alloc(sp, size);
    if (sp->data == NULL) {
        return NGX_ERROR;
    }
    ngx_memzero(sp->data, size);
    return NGX_OK;
}

/* isonim_boundary on|off */
static char *
ngx_http_isonim_boundary(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    char                         *rv;
    size_t                        size;
    ngx_shm_zone_t               *zone;
    ngx_http_isonim_srv_conf_t   *iscf = conf;
    ngx_http_isonim_main_conf_t  *imcf;
    static ngx_str_t              name = ngx_string("isonim_boundary_slots");

    rv = ngx_conf_set_flag_slot(cf, cmd, conf);
    if (rv != NGX_CONF_OK || !iscf->enabled) {
        return rv;
    }

    imcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_isonim_module);
    if (imcf->boundary_zone != NULL) {
        return NGX_CONF_OK;
    }

    size = ngx_max((size_t) (64 * 1024), 8 * ngx_pagesize);
    zone = ngx_shared_memory_add(cf, &name, size,
                                 &ngx_http_isonim_boundary_zone_tag);
    if (zone == NULL) {
        return NGX_CONF_ERROR;
    }
    zone->init = ngx_http_isonim_boundary_zone_init;
    zone->data = imcf;
    zone->noreuse = 1;
    imcf->boundary_zone = zone;
    return NGX_CONF_OK;
}

/* --- The per-slot counts and the worker's pool ---------------------- */

static ngx_atomic_t *
ngx_http_isonim_boundary_slots(void)
{
    ngx_http_isonim_main_conf_t  *imcf;
    ngx_slab_pool_t              *sp;

    imcf = ngx_http_cycle_get_module_main_conf((ngx_cycle_t *) ngx_cycle,
                                               ngx_http_isonim_module);
    if (imcf == NULL || imcf->boundary_zone == NULL) {
        return NULL;
    }
    sp = (ngx_slab_pool_t *) imcf->boundary_zone->shm.addr;
    return sp->data;
}

static ngx_uint_t
ngx_http_isonim_boundary_workers(void)
{
    ngx_core_conf_t  *ccf;

    ccf = (ngx_core_conf_t *) ngx_get_conf(ngx_cycle->conf_ctx,
                                           ngx_core_module);
    return ccf->worker_processes;
}

/* init_process: a worker (also one respawned after a crash) starts with
 * no channels; the slot's count left by a dead predecessor is reset. */
static ngx_int_t
ngx_http_isonim_init_process(ngx_cycle_t *cycle)
{
    ngx_atomic_t  *slots = ngx_http_isonim_boundary_slots();

    if (slots != NULL && ngx_worker < NGX_HTTP_ISONIM_BOUNDARY_MAX_SLOTS) {
        slots[ngx_worker] = 0;
    }
    return NGX_OK;
}

/* The channels in this worker's slot, as its handshake reports them. */
static ngx_uint_t
ngx_http_isonim_boundary_channels_in_slot(void)
{
    return ngx_http_isonim_boundary_nchannels;
}

/* Called from Nim: the worker's slot (ngx_worker) and worker count. */
ngx_uint_t
ngx_http_isonim_boundary_worker_slot(void)
{
    return ngx_worker;
}

ngx_uint_t
ngx_http_isonim_boundary_worker_count(void)
{
    return ngx_http_isonim_boundary_workers();
}

/* Called from Nim: this worker's attached channels. */
ngx_uint_t
ngx_http_isonim_boundary_channel_count(void)
{
    return ngx_http_isonim_boundary_nchannels;
}

/* Called from Nim: the node's channels in `slot` (the per-slot counts
 * zone), or -1 when there is no such zone or slot. */
ngx_int_t
ngx_http_isonim_boundary_slot_count(ngx_uint_t slot)
{
    ngx_atomic_t  *slots = ngx_http_isonim_boundary_slots();

    if (slots == NULL || slot >= NGX_HTTP_ISONIM_BOUNDARY_MAX_SLOTS) {
        return -1;
    }
    return (ngx_int_t) slots[slot];
}

static void
ngx_http_isonim_boundary_attach(ngx_http_isonim_bch_t *ch)
{
    ngx_atomic_t  *slots;

    if (!ngx_http_isonim_boundary_inited) {
        ngx_queue_init(&ngx_http_isonim_boundary_channels);
        ngx_http_isonim_boundary_inited = 1;
    }
    ngx_queue_insert_tail(&ngx_http_isonim_boundary_channels, &ch->queue);
    ngx_http_isonim_boundary_nchannels++;
    ch->attached = 1;

    slots = ngx_http_isonim_boundary_slots();
    if (slots != NULL && ngx_worker < NGX_HTTP_ISONIM_BOUNDARY_MAX_SLOTS) {
        (void) ngx_atomic_fetch_add(&slots[ngx_worker], 1);
    }
}

/* Takes the channel out of the worker's pool and tells Nim, once. */
static void
ngx_http_isonim_boundary_detach(ngx_http_isonim_bch_t *ch)
{
    ngx_atomic_t  *slots;
    void          *state;

    if (ch->attached) {
        ch->attached = 0;
        ngx_queue_remove(&ch->queue);
        ngx_http_isonim_boundary_nchannels--;
        slots = ngx_http_isonim_boundary_slots();
        if (slots != NULL && ngx_worker < NGX_HTTP_ISONIM_BOUNDARY_MAX_SLOTS) {
            (void) ngx_atomic_fetch_add(&slots[ngx_worker], -1);
        }
    }
    state = ch->nim_state;
    ch->nim_state = NULL;
    if (state != NULL) {
        nim_boundary_closed(state);
    }
}

/* --- Certificates ---------------------------------------------------- */

#if (NGX_HTTP_SSL)

/* The workload identity of a certificate: its one URI SAN of the form
 * spiffe://isonim-platform/app/{app}/class/{class}/node/{node_id}
 * (isonim-platform-control-plane.md §8.4), split into its segments
 * (copied into `pool`).  NGX_DECLINED: no such SAN; NGX_ERROR: more than
 * one, or a malformed one. */
static ngx_int_t
ngx_http_isonim_workload_id(X509 *cert, ngx_pool_t *pool, ngx_str_t *app,
    ngx_str_t *cls, ngx_str_t *node)
{
    int                    i, n, len;
    const u_char          *data, *p, *end, *seg;
    ngx_int_t              rc;
    ngx_str_t             *parts[3];
    GENERAL_NAME          *gn;
    GENERAL_NAMES         *names;
    static const char     *labels[3] = { "", "/class/", "/node/" };
    size_t                 plen;
    int                    k;

    names = X509_get_ext_d2i(cert, NID_subject_alt_name, NULL, NULL);
    if (names == NULL) {
        return NGX_DECLINED;
    }

    rc = NGX_DECLINED;
    parts[0] = app;
    parts[1] = cls;
    parts[2] = node;
    plen = sizeof(NGX_HTTP_ISONIM_SPIFFE_PREFIX) - 1;
    n = sk_GENERAL_NAME_num(names);

    for (i = 0; i < n; i++) {
        gn = sk_GENERAL_NAME_value(names, i);
        if (gn->type != GEN_URI) {
            continue;
        }
        data = ASN1_STRING_get0_data(gn->d.uniformResourceIdentifier);
        len = ASN1_STRING_length(gn->d.uniformResourceIdentifier);
        if (len <= (int) plen
            || ngx_strncmp(data, NGX_HTTP_ISONIM_SPIFFE_PREFIX, plen) != 0)
        {
            continue;
        }
        if (rc != NGX_DECLINED) {
            rc = NGX_ERROR;          /* two workload identities */
            break;
        }

        p = data + plen;
        end = data + len;
        rc = NGX_OK;
        for (k = 0; k < 3 && rc == NGX_OK; k++) {
            size_t ll = ngx_strlen(labels[k]);
            if (ll > 0) {
                if ((size_t) (end - p) < ll
                    || ngx_strncmp(p, labels[k], ll) != 0)
                {
                    rc = NGX_ERROR;
                    break;
                }
                p += ll;
            }
            seg = p;
            while (p < end && *p != '/') {
                p++;
            }
            if (p == seg) {
                rc = NGX_ERROR;
                break;
            }
            parts[k]->len = p - seg;
            parts[k]->data = ngx_pnalloc(pool, parts[k]->len);
            if (parts[k]->data == NULL) {
                rc = NGX_ERROR;
                break;
            }
            ngx_memcpy(parts[k]->data, seg, parts[k]->len);
        }
        if (rc == NGX_OK && p != end) {
            rc = NGX_ERROR;          /* trailing segments */
        }
        if (rc == NGX_ERROR) {
            break;
        }
    }

    GENERAL_NAMES_free(names);
    return rc;
}

/* Seconds from now to the certificate's notAfter (<= 0: expired). */
static ngx_int_t
ngx_http_isonim_cert_remaining(X509 *cert, time_t *not_after)
{
    int  days, secs;

    if (!ASN1_TIME_diff(&days, &secs, NULL, X509_get0_notAfter(cert))) {
        return -1;
    }
    *not_after = ngx_time() + (time_t) days * 86400 + secs;
    return (ngx_int_t) days * 86400 + secs;
}

#endif

/* --- The channel's stream ------------------------------------------- */

/* Frees the bytes of the frames nginx has written (their bufs are
 * emptied in order). */
static void
ngx_http_isonim_boundary_reclaim(ngx_http_isonim_bch_t *ch)
{
    ngx_chain_t  *cl;

    while (ch->busy != NULL && ngx_buf_size(ch->busy->buf) == 0) {
        cl = ch->busy;
        ch->busy = cl->next;
        ngx_free(cl->buf->start);
        cl->buf->start = NULL;
        cl->next = ch->free;
        ch->free = cl;
    }
    if (ch->busy == NULL) {
        ch->busy_tail = &ch->busy;
    }
}

/* After an output filter call: reclaim, and keep send_timeout running
 * while output is pending, as ngx_http_writer does. */
static ngx_int_t
ngx_http_isonim_boundary_after_output(ngx_http_isonim_bch_t *ch, ngx_int_t rc)
{
    ngx_http_request_t        *r = ch->request;
    ngx_event_t               *wev = r->connection->write;
    ngx_http_core_loc_conf_t  *clcf;

    if (rc == NGX_ERROR) {
        ngx_log_error(NGX_LOG_INFO, r->connection->log, 0,
                      "isonim boundary: writing to the channel failed");
        if (!ch->close_ev.posted && !ch->finished) {
            ngx_post_event(&ch->close_ev, &ngx_posted_events);
        }
        return NGX_ERROR;
    }

    ngx_http_isonim_boundary_reclaim(ch);

    if (r->buffered || r->postponed || r->connection->buffered || r->out) {
        if (!wev->timer_set) {
            clcf = ngx_http_get_module_loc_conf(r, ngx_http_core_module);
            ngx_add_timer(wev, clcf->send_timeout);
        }
    } else if (wev->timer_set) {
        ngx_del_timer(wev);
    }
    return NGX_OK;
}

/* Called from Nim: hands one whole frame (length prefix included) to
 * nginx on this channel.  Returns NGX_OK (sent, or queued behind the
 * stream's flow control), NGX_DECLINED (the channel is closing) or
 * NGX_ERROR. */
ngx_int_t
ngx_http_isonim_boundary_send(void *channel, const u_char *data, size_t len)
{
    ngx_http_isonim_bch_t  *ch = channel;
    ngx_http_request_t     *r = ch->request;
    ngx_chain_t            *cl, out;
    ngx_buf_t              *b;
    u_char                 *p;
    ngx_int_t               rc;

    if (ch->finished || ch->close_ev.posted || len == 0) {
        return NGX_DECLINED;
    }

    p = ngx_alloc(len, r->connection->log);
    if (p == NULL) {
        return NGX_ERROR;
    }

    if (ch->free != NULL) {
        cl = ch->free;
        ch->free = cl->next;
        b = cl->buf;
    } else {
        cl = ngx_alloc_chain_link(r->pool);
        b = ngx_calloc_buf(r->pool);
        if (cl == NULL || b == NULL) {
            ngx_free(p);
            return NGX_ERROR;
        }
        cl->buf = b;
    }
    ngx_memzero(b, sizeof(ngx_buf_t));
    ngx_memcpy(p, data, len);
    b->start = p;
    b->pos = p;
    b->last = p + len;
    b->end = p + len;
    b->temporary = 1;
    b->flush = 1;
    b->tag = (ngx_buf_tag_t) &ngx_http_isonim_boundary_send;
    cl->next = NULL;
    *ch->busy_tail = cl;
    ch->busy_tail = &cl->next;

    /* nginx's write filter keeps its own links to the buf. */
    out.buf = b;
    out.next = NULL;
    rc = ngx_http_output_filter(r, &out);
    return ngx_http_isonim_boundary_after_output(ch, rc);
}

/* Called from Nim: close the channel (a protocol violation by the
 * peer).  The close is posted, so it never finalizes the request from
 * inside a frame handler. */
void
ngx_http_isonim_boundary_close(void *channel)
{
    ngx_http_isonim_bch_t  *ch = channel;

    if (!ch->finished && !ch->close_ev.posted) {
        ngx_post_event(&ch->close_ev, &ngx_posted_events);
    }
}

static void
ngx_http_isonim_boundary_hold_handler(ngx_event_t *ev)
{
    if (ngx_http_isonim_boundary_holding) {
        ngx_add_timer(ev, NGX_HTTP_ISONIM_BOUNDARY_HOLD_MS);
    }
}

/* Called from Nim when its calls in flight go from none to some (on = 1)
 * and back (on = 0). */
void
ngx_http_isonim_boundary_hold(ngx_int_t on)
{
    ngx_event_t  *ev = &ngx_http_isonim_boundary_hold_ev;

    if (ev->handler == NULL) {
        ev->handler = ngx_http_isonim_boundary_hold_handler;
        ev->log = ngx_cycle->log;
        /* Deliberately not cancelable: it is what keeps an exiting worker
         * alive until its in-flight calls are answered or time out. */
        ev->cancelable = 0;
    }
    ngx_http_isonim_boundary_holding = on ? 1 : 0;
    if (on && !ev->timer_set) {
        ngx_add_timer(ev, NGX_HTTP_ISONIM_BOUNDARY_HOLD_MS);
    } else if (!on && ev->timer_set) {
        ngx_del_timer(ev);
    }
}

/* A posted close (and the expiry below) runs outside nginx's request
 * handler, so it runs the connection's posted requests itself: finalizing
 * an HTTP/2 stream posts its termination there. */
static void
ngx_http_isonim_boundary_close_handler(ngx_event_t *ev)
{
    ngx_http_isonim_bch_t  *ch = ev->data;
    ngx_connection_t       *c = ch->request->connection;

    ngx_http_isonim_boundary_finish(ch, NGX_ERROR);
    ngx_http_run_posted_requests(c);
    nim_async_pump();
}

/* When the channel must end: the earlier of the peer certificate's
 * notAfter and the node's own (the certificate this connection's TLS
 * handshake presented).  A channel never outlives either: a renewed
 * certificate reaches new connections only (a reload's new workers), so
 * a channel kept on an old worker through a reload (the hold below) is
 * closed at its old certificate's notAfter at the latest. */
static time_t
ngx_http_isonim_boundary_ends(ngx_http_isonim_bch_t *ch)
{
    /* MUTATION (the node's own certificate's expiry not enforced): return
     * ch->peer_not_after. */
    if (ch->own_not_after > 0 && ch->own_not_after < ch->peer_not_after) {
        return ch->own_not_after;
    }
    return ch->peer_not_after;
}

static void
ngx_http_isonim_boundary_expiry_handler(ngx_event_t *ev)
{
    ngx_http_isonim_bch_t  *ch = ev->data;
    ngx_connection_t       *c = ch->request->connection;
    time_t                  left;

    left = ngx_http_isonim_boundary_ends(ch) - ngx_time();
    if (left > 0) {
        /* Long lifetimes are timed in steps of at most an hour. */
        ngx_add_timer(ev, (ngx_msec_t) ngx_min(left, 3600) * 1000);
        return;
    }
    if (ch->peer_not_after <= ngx_time()) {
        ngx_log_error(NGX_LOG_INFO, ch->request->connection->log, 0,
                      "isonim boundary: the peer certificate of node \"%V\" "
                      "expired; closing its channel", &ch->peer_node);
    } else {
        ngx_log_error(NGX_LOG_INFO, ch->request->connection->log, 0,
                      "isonim boundary: this node's certificate that the "
                      "channel of node \"%V\" was opened on expired; "
                      "closing the channel", &ch->peer_node);
    }
    ngx_http_isonim_boundary_finish(ch, NGX_ERROR);
    ngx_http_run_posted_requests(c);
    nim_async_pump();
}

/* The request pool is being destroyed: whatever ended the channel (its
 * close, the peer's reset, the connection's loss, nginx terminating the
 * request), Nim learns of it here last. */
static void
ngx_http_isonim_boundary_cleanup(void *data)
{
    ngx_http_isonim_bch_t  *ch = data;
    ngx_chain_t            *cl;

    if (ch->expiry.timer_set) {
        ngx_del_timer(&ch->expiry);
    }
    if (ch->close_ev.posted) {
        ngx_delete_posted_event(&ch->close_ev);
    }
    ngx_http_isonim_boundary_detach(ch);
    /* The stream is closed: nginx holds no frame of ours any more. */
    for (cl = ch->busy; cl; cl = cl->next) {
        if (cl->buf->start != NULL) {
            ngx_free(cl->buf->start);
            cl->buf->start = NULL;
        }
    }
    ch->busy = NULL;
    /* Failed calls complete on Nim's event loop. */
    ngx_http_isonim_async_arm(0);
}

static void
ngx_http_isonim_boundary_finish(ngx_http_isonim_bch_t *ch, ngx_int_t rc)
{
    if (ch->finished) {
        return;
    }
    ch->finished = 1;
    if (ch->close_ev.posted) {
        ngx_delete_posted_event(&ch->close_ev);
    }
    if (ch->expiry.timer_set) {
        ngx_del_timer(&ch->expiry);
    }
    ngx_http_isonim_boundary_detach(ch);
    ngx_http_finalize_request(ch->request, rc);
}

/* The peer's frames: read what nginx has (unbuffered), hand the bytes to
 * Nim, mark them consumed, and read again, which frees nginx's buffer and
 * reopens the stream's flow-control window (WINDOW_UPDATE). */
static void
ngx_http_isonim_boundary_read(ngx_http_request_t *r)
{
    ngx_http_isonim_bch_t  *ch;
    ngx_chain_t            *cl;
    ngx_buf_t              *b;
    ngx_int_t               rc;
    ngx_flag_t              ended = 0, got;

    ch = ngx_http_get_module_ctx(r, ngx_http_isonim_module);
    if (ch == NULL || ch->kind != NGX_HTTP_ISONIM_CTX_BOUNDARY
        || ch->finished || ch->close_ev.posted)
    {
        return;
    }

    /* The channel's end is always posted (ngx_http_isonim_boundary_close):
     * this handler also runs from inside the content handler (opened),
     * where the request must not be finalized. */
    for ( ;; ) {
        rc = ngx_http_read_unbuffered_request_body(r);
        if (rc >= NGX_HTTP_SPECIAL_RESPONSE || rc == NGX_ERROR) {
            ngx_log_error(NGX_LOG_INFO, r->connection->log, 0,
                          "isonim boundary: channel of node \"%V\" ended "
                          "while reading (%i)", &ch->peer_node, rc);
            ngx_http_isonim_boundary_close(ch);
            break;
        }

        cl = r->request_body->bufs;
        r->request_body->bufs = NULL;
        got = (cl != NULL);

        for ( /* void */ ; cl; cl = cl->next) {
            b = cl->buf;
            if (b->last > b->pos && ch->nim_state != NULL) {
                nim_boundary_data(ch->nim_state, b->pos, b->last - b->pos);
            }
            b->pos = b->last;
            if (b->last_buf) {
                ended = 1;
            }
        }

        if (rc == NGX_OK || ended) {
            /* The peer ended its request body: the channel is over. */
            ngx_log_error(NGX_LOG_INFO, r->connection->log, 0,
                          "isonim boundary: the peer \"%V\" ended its "
                          "channel", &ch->peer_node);
            ngx_http_isonim_boundary_close(ch);
            break;
        }

        if (!got || ch->close_ev.posted) {
            /* Nothing new: this call also freed nginx's busy buffer and
             * reopened the stream's window. */
            break;
        }
    }

    /* A channel may be idle for as long as it lives: client_body_timeout
     * (which nginx re-arms on every read) does not apply to it.  A dead
     * peer is noticed by the connection (and a stuck one by send_timeout
     * on writes). */
    if (r->connection->read->timer_set) {
        ngx_del_timer(r->connection->read);
    }

    nim_async_pump();
}

static void
ngx_http_isonim_boundary_write(ngx_http_request_t *r)
{
    ngx_http_isonim_bch_t  *ch;
    ngx_event_t            *wev = r->connection->write;
    ngx_int_t               rc;

    ch = ngx_http_get_module_ctx(r, ngx_http_isonim_module);
    if (ch == NULL || ch->kind != NGX_HTTP_ISONIM_CTX_BOUNDARY
        || ch->finished)
    {
        return;
    }

    if (wev->timedout) {
        ngx_log_error(NGX_LOG_INFO, r->connection->log, NGX_ETIMEDOUT,
                      "isonim boundary: the peer \"%V\" did not read its "
                      "channel within send_timeout", &ch->peer_node);
        r->connection->timedout = 1;
        ngx_http_isonim_boundary_finish(ch, NGX_ERROR);
        nim_async_pump();
        return;
    }

    rc = ngx_http_output_filter(r, NULL);
    (void) ngx_http_isonim_boundary_after_output(ch, rc);
}

/* The body reading has started (no buffering: at once).  Answer 200,
 * put the channel in the worker's pool and let Nim send the handshake. */
static void
ngx_http_isonim_boundary_opened(ngx_http_request_t *r)
{
    ngx_http_isonim_bch_t  *ch;
    ngx_int_t               rc;
    ngx_buf_t              *b;
    ngx_chain_t             out;
    static ngx_str_t        type = ngx_string("application/octet-stream");

    ch = ngx_http_get_module_ctx(r, ngx_http_isonim_module);

    if (!r->request_body_no_buffering) {
        /* The peer ended its stream with the request: there is no
         * channel to hold open. */
        ngx_log_error(NGX_LOG_INFO, r->connection->log, 0,
                      "isonim boundary: the peer ended the channel request "
                      "at once");
        ngx_http_finalize_request(r, NGX_HTTP_BAD_REQUEST);
        return;
    }

    if (r->connection->read->timer_set) {
        ngx_del_timer(r->connection->read);
    }

    r->headers_out.status = NGX_HTTP_OK;
    r->headers_out.content_length_n = -1;
    r->headers_out.content_type = type;
    r->headers_out.content_type_len = type.len;
    r->headers_out.content_type_lowcase = NULL;

    /* From here on a failure posts the close: this runs inside the
     * content handler (ngx_http_read_client_request_body calls it at
     * once), where terminating the request would free it under nginx. */
    rc = ngx_http_send_header(r);
    if (rc == NGX_ERROR || rc > NGX_OK || r->header_only) {
        ngx_http_isonim_boundary_close(ch);
        return;
    }

    /* Put the HEADERS frame on the wire now. */
    b = ngx_calloc_buf(r->pool);
    if (b == NULL) {
        ngx_http_isonim_boundary_close(ch);
        return;
    }
    b->flush = 1;
    out.buf = b;
    out.next = NULL;
    rc = ngx_http_output_filter(r, &out);
    if (ngx_http_isonim_boundary_after_output(ch, rc) != NGX_OK) {
        ngx_http_isonim_boundary_close(ch);
        return;
    }

    r->read_event_handler = ngx_http_isonim_boundary_read;
    r->write_event_handler = ngx_http_isonim_boundary_write;

    ngx_http_isonim_boundary_attach(ch);

    if (ch->peer_not_after > 0) {
        ch->expiry.handler = ngx_http_isonim_boundary_expiry_handler;
        ch->expiry.data = ch;
        ch->expiry.log = r->connection->log;
        /* An expiry alone never keeps an exiting worker alive. */
        ch->expiry.cancelable = 1;
        ngx_add_timer(&ch->expiry, (ngx_msec_t)
            ngx_min(ngx_max(ngx_http_isonim_boundary_ends(ch) - ngx_time(), 0),
                    3600) * 1000);
    }

    ch->nim_state = nim_boundary_open(ch,
        ch->node_id.data, ch->node_id.len,
        ch->peer_node.data, ch->peer_node.len,
        ngx_worker, ngx_http_isonim_boundary_workers(),
        ngx_http_isonim_boundary_channels_in_slot(),
        ch->conf->min_channels, ch->conf->max_frame);

    if (ch->nim_state == NULL) {
        ngx_http_isonim_boundary_close(ch);
        return;
    }

    /* What the peer has already sent (its handshake, perhaps). */
    ngx_http_isonim_boundary_read(r);
}

/* POST /_boundary/v1/channel at an isonim_boundary server. */
static ngx_int_t
ngx_http_isonim_boundary_handler(ngx_http_request_t *r,
    ngx_http_isonim_srv_conf_t *iscf)
{
#if (NGX_HTTP_SSL)
    ngx_http_isonim_bch_t  *ch;
    ngx_pool_cleanup_t     *cln;
    ngx_connection_t       *c = r->connection;
    ngx_str_t               app, cls, node, own_app, own_cls, own_node;
    X509                   *cert;
    ngx_int_t               rc, left, own_left;
    time_t                  not_after = 0, own_not_after = 0;
    static ngx_str_t        path = ngx_string(NGX_HTTP_ISONIM_BOUNDARY_PATH);

    if (r != r->main) {
        return NGX_DECLINED;
    }
    if (r->uri.len != path.len
        || ngx_strncmp(r->uri.data, path.data, path.len) != 0)
    {
        return NGX_HTTP_NOT_FOUND;
    }
    if (r->method != NGX_HTTP_POST) {
        return NGX_HTTP_NOT_ALLOWED;
    }
    if (r->http_version != NGX_HTTP_VERSION_20) {
        /* A channel is one long-lived HTTP/2 stream; there is no HTTP/1.1
         * fallback. */
        ngx_log_error(NGX_LOG_ERR, c->log, 0,
                      "isonim boundary: a channel needs HTTP/2, the peer "
                      "sent HTTP/%ui.%ui", r->http_major, r->http_minor);
        return NGX_HTTP_VERSION_NOT_SUPPORTED;
    }
    if (c->ssl == NULL) {
        return NGX_HTTP_FORBIDDEN;
    }

    /* nginx has verified the chain (ssl_verify_client on, checked by
     * nginx -t); check again, then the workload class. */
    if (SSL_get_verify_result(c->ssl->connection) != X509_V_OK) {
        return NGX_HTTP_FORBIDDEN;
    }
    cert = SSL_get_peer_certificate(c->ssl->connection);
    if (cert == NULL) {
        return NGX_HTTP_FORBIDDEN;
    }
    rc = ngx_http_isonim_workload_id(cert, r->pool, &app, &cls, &node);
    left = ngx_http_isonim_cert_remaining(cert, &not_after);
    X509_free(cert);

    if (rc != NGX_OK) {
        ngx_log_error(NGX_LOG_WARN, c->log, 0,
                      "isonim boundary: refused a peer whose certificate "
                      "carries no single workload identity");
        return NGX_HTTP_FORBIDDEN;
    }
    if (cls.len != iscf->peer_class.len
        || ngx_strncmp(cls.data, iscf->peer_class.data, cls.len) != 0)
    {
        ngx_log_error(NGX_LOG_WARN, c->log, 0,
                      "isonim boundary: refused node \"%V\" of class \"%V\" "
                      "(isonim_boundary_peer_class is \"%V\")",
                      &node, &cls, &iscf->peer_class);
        return NGX_HTTP_FORBIDDEN;
    }
    if (left <= 0) {
        ngx_log_error(NGX_LOG_WARN, c->log, 0,
                      "isonim boundary: refused node \"%V\": its certificate "
                      "has expired", &node);
        return NGX_HTTP_FORBIDDEN;
    }

    /* The node's own identity, from the certificate it serves. */
    cert = SSL_get_certificate(c->ssl->connection);
    if (cert == NULL
        || ngx_http_isonim_workload_id(cert, r->pool, &own_app, &own_cls,
                                       &own_node) != NGX_OK)
    {
        ngx_log_error(NGX_LOG_ERR, c->log, 0,
                      "isonim boundary: this server's certificate carries "
                      "no workload identity (a spiffe://isonim-platform/... "
                      "URI SAN); it cannot open channels");
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }
    /* SSL_get_certificate does not take a reference: not freed. */
    own_left = ngx_http_isonim_cert_remaining(cert, &own_not_after);
    if (own_left <= 0) {
        /* The node serves a certificate that has expired: its renewal has
         * not reached this worker (isonim-platform-control-plane.md §8.4,
         * the renewal signal).  A peer that verifies the node refuses it
         * at the handshake; one that did not is refused here, so no
         * channel ever runs on an expired certificate of either end. */
        ngx_log_error(NGX_LOG_ERR, c->log, 0,
                      "isonim boundary: refused node \"%V\": this node's "
                      "own certificate has expired (its renewal has not "
                      "been loaded)", &node);
        return NGX_HTTP_SERVICE_UNAVAILABLE;
    }
    if (app.len != own_app.len
        || ngx_strncmp(app.data, own_app.data, app.len) != 0)
    {
        ngx_log_error(NGX_LOG_WARN, c->log, 0,
                      "isonim boundary: refused node \"%V\" of app \"%V\" "
                      "(this node's app is \"%V\")", &node, &app, &own_app);
        return NGX_HTTP_FORBIDDEN;
    }

    ch = ngx_pcalloc(r->pool, sizeof(ngx_http_isonim_bch_t));
    cln = ngx_pool_cleanup_add(r->pool, 0);
    if (ch == NULL || cln == NULL) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }
    ch->kind = NGX_HTTP_ISONIM_CTX_BOUNDARY;
    ch->request = r;
    ch->conf = iscf;
    ch->node_id = own_node;
    ch->peer_node = node;
    ch->peer_not_after = not_after;
    ch->own_not_after = own_not_after;
    ch->busy_tail = &ch->busy;
    ch->close_ev.handler = ngx_http_isonim_boundary_close_handler;
    ch->close_ev.data = ch;
    ch->close_ev.log = c->log;
    ngx_http_set_ctx(r, ch, ngx_http_isonim_module);
    cln->handler = ngx_http_isonim_boundary_cleanup;
    cln->data = ch;

    /* The channel's request body is unbounded and has no length: without
     * one, nginx would hold it to client_max_body_size.  A length no
     * stream reaches lifts that limit for this request only (frames are
     * bounded one by one, by isonim_boundary_max_frame). */
    r->headers_in.content_length_n = NGX_MAX_OFF_T_VALUE;
    r->request_body_no_buffering = 1;

    rc = ngx_http_read_client_request_body(r, ngx_http_isonim_boundary_opened);
    if (rc >= NGX_HTTP_SPECIAL_RESPONSE) {
        return rc;
    }
    return NGX_DONE;
#else
    return NGX_HTTP_INTERNAL_SERVER_ERROR;
#endif
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
