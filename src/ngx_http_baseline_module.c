/*
 * ngx_http_baseline_module.c
 *
 * Baseline nginx module for performance comparison. Pure C, no Nim,
 * no external dependencies. Serves hardcoded HTML responses directly
 * from the content handler to establish the theoretical maximum req/s.
 *
 * Two response modes:
 *   /baseline/hello  — small static response (147 bytes, matches isonim hello)
 *   /baseline/tasks  — larger response (~1200 bytes, matches isonim task manager)
 *
 * Both use the simplest possible nginx API pattern:
 *   1. Discard request body
 *   2. Set response headers with known Content-Length
 *   3. Send headers
 *   4. Allocate one ngx_buf_t from the pool
 *   5. Copy response into the buffer
 *   6. Mark last_buf, call ngx_http_output_filter
 */

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>

/* ------------------------------------------------------------------ */
/* Hardcoded responses                                                */
/* ------------------------------------------------------------------ */

static const char HELLO_HTML[] =
    "<html><body><h1>Hello from IsoNim</h1></body></html>"
    "<script>window._$HY={events:[\"click\",\"input\"],"
    "completed:new WeakSet,registry:new Map};</script>";

static const char TASKS_HTML[] =
    "<div class=\"app\">"
    "<header class=\"page-header\">"
    "<h1>IsoNim Task Manager</h1>"
    "<p class=\"subtitle\">Served by nginx + IsoNim SSR</p>"
    "</header>"
    "<section class=\"task-section\">"
    "<div class=\"task-header\"><h2>Tasks</h2>"
    "<span class=\"count\">3 active</span></div>"
    "<ul class=\"task-list\">"
    "<li class=\"task completed\"><input type=\"checkbox\" checked=\"true\" />"
    "<span class=\"task-text\">Learn IsoNim reactive framework</span>"
    "<button class=\"remove\">x</button></li>"
    "<li class=\"task completed\"><input type=\"checkbox\" checked=\"true\" />"
    "<span class=\"task-text\">Build nginx SSR module</span>"
    "<button class=\"remove\">x</button></li>"
    "<li class=\"task\"><input type=\"checkbox\" checked=\"false\" />"
    "<span class=\"task-text\">Write E2E tests</span>"
    "<button class=\"remove\">x</button></li>"
    "<li class=\"task\"><input type=\"checkbox\" checked=\"false\" />"
    "<span class=\"task-text\">Deploy to production</span>"
    "<button class=\"remove\">x</button></li>"
    "<li class=\"task\"><input type=\"checkbox\" checked=\"false\" />"
    "<span class=\"task-text\">Celebrate!</span>"
    "<button class=\"remove\">x</button></li>"
    "</ul>"
    "</section>"
    "<footer class=\"app-footer\">"
    "<p>Powered by IsoNim + nginx</p>"
    "</footer>"
    "</div>"
    "<script>window._$HY={events:[\"click\",\"input\"],"
    "completed:new WeakSet,registry:new Map};</script>";

/* ------------------------------------------------------------------ */
/* Streaming response — same content but sent via chunked transfer    */
/* using the same pattern as the isonim streaming handler.            */
/* This tests whether ngx_http_output_filter works correctly when     */
/* called multiple times for chunked responses.                       */
/* ------------------------------------------------------------------ */

static ngx_int_t
ngx_http_baseline_streaming_handler(ngx_http_request_t *r,
                                    const char *html, size_t html_len)
{
    ngx_int_t   rc;
    ngx_buf_t  *b;
    ngx_chain_t out;

    /* Headers — no Content-Length, let nginx use chunked. */
    r->headers_out.status = NGX_HTTP_OK;
    r->headers_out.content_type_len = sizeof("text/html; charset=utf-8") - 1;
    ngx_str_set(&r->headers_out.content_type, "text/html; charset=utf-8");
    r->headers_out.content_length_n = -1;

    rc = ngx_http_send_header(r);
    if (rc == NGX_ERROR || rc > NGX_OK || r->header_only) {
        return rc;
    }

    /* Send the body as a single chunk via output_filter. */
    b = ngx_create_temp_buf(r->pool, html_len);
    if (b == NULL) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }
    ngx_memcpy(b->pos, html, html_len);
    b->last = b->pos + html_len;
    b->memory = 1;
    b->last_buf = 1;
    b->last_in_chain = 1;

    out.buf = b;
    out.next = NULL;

    return ngx_http_output_filter(r, &out);
}

/* ------------------------------------------------------------------ */
/* Buffered response — same pattern as the isonim buffered handler.   */
/* ------------------------------------------------------------------ */

static ngx_int_t
ngx_http_baseline_buffered_handler(ngx_http_request_t *r,
                                    const char *html, size_t html_len)
{
    ngx_int_t   rc;
    ngx_buf_t  *b;
    ngx_chain_t out;

    /* Headers with Content-Length. */
    r->headers_out.status = NGX_HTTP_OK;
    r->headers_out.content_length_n = html_len;
    r->headers_out.content_type_len = sizeof("text/html; charset=utf-8") - 1;
    ngx_str_set(&r->headers_out.content_type, "text/html; charset=utf-8");

    rc = ngx_http_send_header(r);
    if (rc == NGX_ERROR || rc > NGX_OK || r->header_only) {
        return rc;
    }

    b = ngx_create_temp_buf(r->pool, html_len);
    if (b == NULL) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }
    ngx_memcpy(b->pos, html, html_len);
    b->last = b->pos + html_len;
    b->memory = 1;
    b->last_buf = 1;
    b->last_in_chain = 1;

    out.buf = b;
    out.next = NULL;

    return ngx_http_output_filter(r, &out);
}

/* ------------------------------------------------------------------ */
/* Content handler — dispatches based on URI.                         */
/* ------------------------------------------------------------------ */

static ngx_int_t
ngx_http_baseline_handler(ngx_http_request_t *r)
{
    ngx_int_t rc;

    if (!(r->method & (NGX_HTTP_GET | NGX_HTTP_HEAD))) {
        return NGX_HTTP_NOT_ALLOWED;
    }

    rc = ngx_http_discard_request_body(r);
    if (rc != NGX_OK) {
        return rc;
    }

    /* Route by URI suffix. */
    if (r->uri.len >= 6 &&
        ngx_strncmp(r->uri.data + r->uri.len - 6, "/tasks", 6) == 0)
    {
        return ngx_http_baseline_buffered_handler(
            r, TASKS_HTML, sizeof(TASKS_HTML) - 1);
    }

    if (r->uri.len >= 10 &&
        ngx_strncmp(r->uri.data + r->uri.len - 10, "/streaming", 10) == 0)
    {
        /* Streaming variant of hello — tests output_filter with chunked. */
        return ngx_http_baseline_streaming_handler(
            r, HELLO_HTML, sizeof(HELLO_HTML) - 1);
    }

    /* Default: hello. */
    return ngx_http_baseline_buffered_handler(
        r, HELLO_HTML, sizeof(HELLO_HTML) - 1);
}

/* ------------------------------------------------------------------ */
/* Module boilerplate — minimal, no config directives needed.         */
/* ------------------------------------------------------------------ */

static ngx_int_t ngx_http_baseline_postconfiguration(ngx_conf_t *cf);

static ngx_http_module_t ngx_http_baseline_module_ctx = {
    NULL,                                     /* preconfiguration */
    ngx_http_baseline_postconfiguration,      /* postconfiguration */
    NULL, NULL, NULL, NULL, NULL, NULL
};

ngx_module_t ngx_http_baseline_module = {
    NGX_MODULE_V1,
    &ngx_http_baseline_module_ctx,
    NULL,                  /* no directives */
    NGX_HTTP_MODULE,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NGX_MODULE_V1_PADDING
};

/* Dynamic module symbols. */
ngx_module_t *ngx_modules[] = {
    &ngx_http_baseline_module,
    NULL
};

char *ngx_module_names[] = {
    "ngx_http_baseline_module",
    NULL
};

char *ngx_module_order[] = { NULL };

static ngx_int_t
ngx_http_baseline_postconfiguration(ngx_conf_t *cf)
{
    ngx_http_handler_pt        *h;
    ngx_http_core_main_conf_t  *cmcf;

    cmcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_core_module);

    h = ngx_array_push(&cmcf->phases[NGX_HTTP_CONTENT_PHASE].handlers);
    if (h == NULL) {
        return NGX_ERROR;
    }

    *h = ngx_http_baseline_handler;
    return NGX_OK;
}
