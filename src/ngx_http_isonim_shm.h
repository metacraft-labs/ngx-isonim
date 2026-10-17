/*
 * ngx_http_isonim_shm.h
 *
 * The layout shared by the C side of the module (ngx_http_isonim_module.c:
 * the isonim_shm_zone directive, the zone's init callback and the reload
 * check) and the Nim side (shm_table.nim: the table's operations) of an
 * application shared-memory zone.  It deliberately depends on nothing but
 * <stdint.h> and <stddef.h>, so that the mock-mode unit tests
 * (-d:isNginxTest), which have no nginx headers, compile the same layout.
 *
 * A zone is an nginx shared-memory zone (ngx_shared_memory_add) whose slab
 * pool (ngx_slab_pool_t, at the start of the segment) holds one table.  The
 * pool's `data` member points at the zone header below; it is NULL until a
 * worker first binds the zone (shm_table.nim initializes the header then,
 * under the pool's mutex), so nothing in the master process allocates.
 *
 * The header's first members (magic, layout, size, max_value) are what the
 * master reads at a reload to decide whether the new configuration's zone
 * may keep the old contents (spec/isonim-nginx.md, "Reload").  Bump
 * NGX_HTTP_ISONIM_SHM_LAYOUT whenever this struct or the entry layout in
 * shm_table.nim changes: a zone with another layout is never reused.
 */

#ifndef NGX_HTTP_ISONIM_SHM_H_INCLUDED
#define NGX_HTTP_ISONIM_SHM_H_INCLUDED

#include <stddef.h>
#include <stdint.h>

/* "ISHMZONE" */
#define NGX_HTTP_ISONIM_SHM_MAGIC           0x4953484D5A4F4E45ULL
#define NGX_HTTP_ISONIM_SHM_LAYOUT          1u
#define NGX_HTTP_ISONIM_SHM_CODEC_NAME_MAX  64

typedef struct {
    uint64_t   magic;            /* NGX_HTTP_ISONIM_SHM_MAGIC once set up  */
    uint32_t   layout;           /* NGX_HTTP_ISONIM_SHM_LAYOUT             */
    uint32_t   codec_set;        /* 1 once a typed table recorded a codec  */
    uint64_t   size;             /* the zone's size= (bytes)               */
    uint64_t   max_value;        /* the zone's max_value= (bytes)          */

    uint64_t   hash_k0;          /* SipHash key, random per zone           */
    uint64_t   hash_k1;
    uint64_t   next_version;     /* the next store's version (from 1)      */

    void      *buckets;          /* nbuckets chain heads (entry pointers)  */
    uint64_t   nbuckets;         /* a power of two                         */
    void      *lru_head;         /* most recently used entry               */
    void      *lru_tail;         /* least recently used entry              */

    uint64_t   entries;
    uint64_t   entry_bytes;      /* bytes allocated for entries            */
    uint64_t   stores;
    uint64_t   evictions;
    uint64_t   refused_full;
    uint64_t   refused_too_large;
    uint64_t   lock_waits;

    uint32_t   codec_version;
    uint32_t   codec_name_len;
    char       codec_name[NGX_HTTP_ISONIM_SHM_CODEC_NAME_MAX];
} ngx_http_isonim_shm_header_t;

/* What ngx_http_isonim_shm_find tells the Nim side about a declared zone
 * (in the worker that asks). */
typedef struct {
    void      *pool;             /* the zone's ngx_slab_pool_t             */
    void     **data;             /* &pool->data: the zone header           */
    uint64_t   size;             /* size= (bytes)                          */
    uint64_t   max_value;        /* max_value= (bytes)                     */
} ngx_http_isonim_shm_info_t;

#endif /* NGX_HTTP_ISONIM_SHM_H_INCLUDED */
