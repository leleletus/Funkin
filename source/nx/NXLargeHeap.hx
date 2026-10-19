package nx;

/**
 * Separate region for large blocks (INC-49, INC-42).
 *
 * newlib's malloc (dlmalloc 2.6) has no mmap threshold: on Switch every block, small or large, comes from the same
 * sbrk arena. After a long session the arena was full of holes: ~2.2 GB free in SOAK but no hole of 91-168 MiB,
 * because small long-lived allocations (GC blocks, Mesa objects, strings) ended up between the big ones.
 *
 * This class replaces the public allocator entry points (malloc, free, realloc, calloc, memalign, aligned_alloc,
 * valloc, pvalloc, malloc_usable_size, reallocf) at link time, like NXAudioDriver replaces SDL's audio driver.
 * Requests of 2 MiB or more (textures and GPU staging from Mesa, decoded images, audio buffers, large GC objects)
 * get a span of 64 KiB granules from a region at the top of the heap that only large blocks use, so freed blocks
 * coalesce again. Everything else keeps using newlib (its _r implementations are untouched). The region grows
 * downwards and gives its bottom back to newlib when it frees, moving fake_heap_end (libnx's sbrk reads it on
 * every call), and always leaves newlib 128 MiB to grow. If the region cannot serve a large request, newlib does,
 * as before; if newlib cannot serve a small one, the region does.
 *
 * Disable with -Dnx_legacy_heap (A/B builds).
 */
#if (switch && cpp && !nx_legacy_heap)
@:cppFileCode('
#include <malloc.h>
#include <reent.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>
#include <errno.h>

extern "C" {
  extern char* fake_heap_start;
  extern char* fake_heap_end;
  void* _sbrk_r(struct _reent*, ptrdiff_t);
}

#define NXL_GRANULE ((uintptr_t)64 << 10)
#define NXL_MIN_REQUEST ((size_t)2 << 20)
#define NXL_NEWLIB_MARGIN ((uintptr_t)128 << 20)
#define NXL_MAGIC 0x31454752414C584EULL

// Written right before every payload: identifies region blocks and their span.
struct nxl_tag { uint64_t magic; uintptr_t spanStart; size_t spanSize; size_t requested; };
// Written at the start of every free span (spans are granule aligned at both ends).
struct nxl_span { size_t size; struct nxl_span* prev; struct nxl_span* next; };

static uintptr_t nxl_top = 0; // region end, the heap end seen at first use
static uintptr_t nxl_low = 0; // region start; read without the lock by nxl_owns
static uintptr_t nxl_deadGap = 0; // test builds: heap cap kept as unusable space between newlib and the region
static struct nxl_span* nxl_head = 0; // free spans, ascending addresses
static struct nxl_span* nxl_tail = 0;
static size_t nxl_used = 0, nxl_peak = 0, nxl_blocks = 0, nxl_spanCount = 0;
static size_t nxl_maxRequest = 0, nxl_fallbacks = 0, nxl_rescues = 0;

static inline uintptr_t nxl_lowAcquire(void) { return __atomic_load_n(&nxl_low, __ATOMIC_ACQUIRE); }

static inline uintptr_t nxl_brk(void) { return (uintptr_t)_sbrk_r(_REENT, 0); }

static void nxl_setNewlibEnd(void) { fake_heap_end = (char*)(nxl_low - nxl_deadGap); }

static int nxl_init(void)
{
  if (nxl_top != 0) return 1;
  if (fake_heap_end == 0) return 0; // heap not set up yet: newlib serves everything
  nxl_top = (uintptr_t)fake_heap_end & ~(NXL_GRANULE - 1);
  __atomic_store_n(&nxl_low, nxl_top, __ATOMIC_RELEASE);
  return 1;
}

static void nxl_unlink(struct nxl_span* s)
{
  if (s->prev) s->prev->next = s->next; else nxl_head = s->next;
  if (s->next) s->next->prev = s->prev; else nxl_tail = s->prev;
  nxl_spanCount--;
}

static void* nxl_finish(uintptr_t spanStart, size_t spanSize, uintptr_t payload, size_t size)
{
  struct nxl_tag* t = (struct nxl_tag*)(payload - sizeof(struct nxl_tag));
  t->magic = NXL_MAGIC;
  t->spanStart = spanStart;
  t->spanSize = spanSize;
  t->requested = size;
  nxl_used += spanSize;
  nxl_blocks++;
  if (nxl_used > nxl_peak) nxl_peak = nxl_used;
  return (void*)payload;
}

// Caller holds __malloc_lock. Highest free span first (long-lived early blocks settle at the top), carving from its
// top end; otherwise the region grows downwards if newlib keeps its margin.
static void* nxl_allocLocked(size_t size, size_t align)
{
  if (!nxl_init()) return 0;
  if (align < 64) align = 64;
  if ((align & (align - 1)) != 0) return 0;
  if (size > ((size_t)1 << 40)) return 0;
  if (size > nxl_maxRequest) nxl_maxRequest = size;
  for (struct nxl_span* f = nxl_tail; f; f = f->prev)
  {
    uintptr_t fStart = (uintptr_t)f;
    uintptr_t fEnd = fStart + f->size;
    if (f->size < size + sizeof(struct nxl_tag)) continue;
    uintptr_t payload = (fEnd - size) & ~(uintptr_t)(align - 1);
    if (payload < fStart + sizeof(struct nxl_tag)) continue;
    uintptr_t spanStart = (payload - sizeof(struct nxl_tag)) & ~(NXL_GRANULE - 1);
    if (spanStart < fStart) continue;
    if (spanStart == fStart) nxl_unlink(f);
    else f->size = spanStart - fStart;
    return nxl_finish(spanStart, fEnd - spanStart, payload, size);
  }
  uintptr_t low = nxl_low;
  if (low < size + 4 * NXL_GRANULE) return 0;
  uintptr_t payload = (low - size) & ~(uintptr_t)(align - 1);
  uintptr_t spanStart = (payload - sizeof(struct nxl_tag)) & ~(NXL_GRANULE - 1);
  uintptr_t limit = nxl_brk() + NXL_NEWLIB_MARGIN + nxl_deadGap;
  if (spanStart < limit) return 0;
  __atomic_store_n(&nxl_low, spanStart, __ATOMIC_RELEASE);
  nxl_setNewlibEnd();
  return nxl_finish(spanStart, low - spanStart, payload, size);
}

static void* nxl_alloc(size_t size, size_t align, int large)
{
  __malloc_lock(_REENT);
  void* p = nxl_allocLocked(size, align);
  if (!p && large) nxl_fallbacks++;
  if (p && !large) nxl_rescues++;
  __malloc_unlock(_REENT);
  return p;
}

static inline struct nxl_tag* nxl_tagOf(void* p) { return (struct nxl_tag*)((uintptr_t)p - sizeof(struct nxl_tag)); }

static int nxl_owns(void* p)
{
  uintptr_t a = (uintptr_t)p;
  if (nxl_top == 0 || a >= nxl_top || a < nxl_lowAcquire() + sizeof(struct nxl_tag)) return 0;
  return nxl_tagOf(p)->magic == NXL_MAGIC;
}

static void nxl_freeLocked(void* p)
{
  struct nxl_tag* t = nxl_tagOf(p);
  uintptr_t start = t->spanStart;
  size_t size = t->spanSize;
  t->magic = 0;
  nxl_used -= size;
  nxl_blocks--;
  struct nxl_span* prev = 0;
  struct nxl_span* next = nxl_head;
  while (next && (uintptr_t)next < start)
  {
    prev = next;
    next = next->next;
  }
  struct nxl_span* s;
  if (prev && (uintptr_t)prev + prev->size == start)
  {
    prev->size += size;
    s = prev;
  }
  else
  {
    s = (struct nxl_span*)start;
    s->size = size;
    s->prev = prev;
    s->next = next;
    if (prev) prev->next = s; else nxl_head = s;
    if (next) next->prev = s; else nxl_tail = s;
    nxl_spanCount++;
  }
  if (next && (uintptr_t)s + s->size == (uintptr_t)next)
  {
    s->size += next->size;
    s->next = next->next;
    if (next->next) next->next->prev = s; else nxl_tail = s;
    nxl_spanCount--;
  }
  if ((uintptr_t)s == nxl_low)
  {
    // The bottom of the region is free: give it back to newlib.
    uintptr_t end = (uintptr_t)s + s->size;
    nxl_unlink(s);
    __atomic_store_n(&nxl_low, end, __ATOMIC_RELEASE);
    nxl_setNewlibEnd();
  }
}

static size_t nxl_capacity(void* p)
{
  struct nxl_tag* t = nxl_tagOf(p);
  return t->spanStart + t->spanSize - (uintptr_t)p;
}

extern "C" {

void* malloc(size_t n)
{
  if (n >= NXL_MIN_REQUEST)
  {
    void* p = nxl_alloc(n, 64, 1);
    if (p) return p;
  }
  void* p = _malloc_r(_REENT, n);
  if (!p && n > 0 && n < NXL_MIN_REQUEST) p = nxl_alloc(n, 64, 0);
  return p;
}

void free(void* p)
{
  if (!p) return;
  if (nxl_owns(p))
  {
    __malloc_lock(_REENT);
    nxl_freeLocked(p);
    __malloc_unlock(_REENT);
    return;
  }
  _free_r(_REENT, p);
}

void* calloc(size_t a, size_t b)
{
  size_t n;
  if (__builtin_mul_overflow(a, b, &n))
  {
    errno = ENOMEM;
    return 0;
  }
  if (n >= NXL_MIN_REQUEST)
  {
    void* p = nxl_alloc(n, 64, 1);
    if (p)
    {
      memset(p, 0, n);
      return p;
    }
  }
  void* p = _calloc_r(_REENT, a, b);
  if (!p && n > 0 && n < NXL_MIN_REQUEST)
  {
    p = nxl_alloc(n, 64, 0);
    if (p) memset(p, 0, n);
  }
  return p;
}

void* memalign(size_t align, size_t n)
{
  if (n >= NXL_MIN_REQUEST)
  {
    void* p = nxl_alloc(n, align, 1);
    if (p) return p;
  }
  void* p = _memalign_r(_REENT, align, n);
  if (!p && n > 0 && n < NXL_MIN_REQUEST) p = nxl_alloc(n, align, 0);
  return p;
}

void* aligned_alloc(size_t align, size_t n)
{
  return memalign(align, n);
}

void* valloc(size_t n)
{
  return memalign(4096, n);
}

void* pvalloc(size_t n)
{
  return memalign(4096, (n + 4095) & ~(size_t)4095);
}

size_t malloc_usable_size(void* p)
{
  if (!p) return 0;
  if (nxl_owns(p)) return nxl_capacity(p);
  return _malloc_usable_size_r(_REENT, p);
}

void* realloc(void* p, size_t n)
{
  if (!p) return malloc(n);
  if (nxl_owns(p))
  {
    if (n == 0)
    {
      free(p);
      return 0;
    }
    size_t cap = nxl_capacity(p);
    if (n <= cap && n >= NXL_MIN_REQUEST / 2) return p;
    void* q = malloc(n);
    if (!q) return 0;
    memcpy(q, p, n < cap ? n : cap);
    free(p);
    return q;
  }
  if (n >= NXL_MIN_REQUEST)
  {
    void* q = nxl_alloc(n, 64, 1);
    if (q)
    {
      size_t old = _malloc_usable_size_r(_REENT, p);
      memcpy(q, p, old < n ? old : n);
      _free_r(_REENT, p);
      return q;
    }
  }
  void* q = _realloc_r(_REENT, p, n);
  if (!q && n > 0 && n < NXL_MIN_REQUEST)
  {
    q = nxl_alloc(n, 64, 0);
    if (q)
    {
      size_t old = _malloc_usable_size_r(_REENT, p);
      memcpy(q, p, old < n ? old : n);
      _free_r(_REENT, p);
    }
  }
  return q;
}

void* reallocf(void* p, size_t n)
{
  void* q = realloc(p, n);
  if (!q && n) free(p);
  return q;
}

void* _reallocf_r(struct _reent* r, void* p, size_t n)
{
  (void)r;
  return reallocf(p, n);
}

// Telemetry and test hooks, also read (weakly) by NXPerformance.
size_t nxl_totalBytes(void)
{
  if (nxl_top == 0) return (size_t)(fake_heap_end - fake_heap_start);
  return (size_t)(nxl_top - (uintptr_t)fake_heap_start - nxl_deadGap);
}

size_t nxl_usedBytes(void) { return nxl_used; }

size_t nxl_largestFree(void)
{
  __malloc_lock(_REENT);
  size_t largest = 0;
  for (struct nxl_span* s = nxl_head; s; s = s->next)
    if (s->size > largest) largest = s->size;
  __malloc_unlock(_REENT);
  return largest;
}

// Largest request the region can serve right now: a free span, or growing down while newlib keeps its margin.
size_t nxl_allocBound(void)
{
  __malloc_lock(_REENT);
  size_t bound = 0;
  for (struct nxl_span* s = nxl_head; s; s = s->next)
    if (s->size > bound) bound = s->size;
  if (nxl_top != 0)
  {
    uintptr_t limit = nxl_brk() + NXL_NEWLIB_MARGIN + nxl_deadGap;
    if (nxl_low > limit + NXL_GRANULE && nxl_low - limit > bound) bound = nxl_low - limit;
  }
  __malloc_unlock(_REENT);
  return bound > 2 * NXL_GRANULE ? bound - 2 * NXL_GRANULE : 0;
}

int nxl_cap(size_t capBytes)
{
  __malloc_lock(_REENT);
  if (!nxl_init())
  {
    __malloc_unlock(_REENT);
    return 3;
  }
  uintptr_t total = nxl_top - (uintptr_t)fake_heap_start;
  if (capBytes >= total)
  {
    __malloc_unlock(_REENT);
    return 1;
  }
  uintptr_t gap = total - capBytes;
  if (nxl_low < gap || nxl_low - gap < nxl_brk() + ((uintptr_t)256 << 20))
  {
    __malloc_unlock(_REENT);
    return 2;
  }
  nxl_deadGap = gap;
  nxl_setNewlibEnd();
  __malloc_unlock(_REENT);
  return 0;
}

struct nxl_stats { double regionBytes, used, freeBytes, largestFree, peak, maxRequest, room; int blocks, spans, fallbacks, rescues; };

static struct nxl_stats nxl_st;

void nxl_readStats(int resetPeak)
{
  __malloc_lock(_REENT);
  size_t freeBytes = 0, largest = 0;
  for (struct nxl_span* s = nxl_head; s; s = s->next)
  {
    freeBytes += s->size;
    if (s->size > largest) largest = s->size;
  }
  uintptr_t limit = nxl_top ? nxl_brk() + NXL_NEWLIB_MARGIN + nxl_deadGap : 0;
  nxl_st.regionBytes = (double)(nxl_top - nxl_low);
  nxl_st.used = (double)nxl_used;
  nxl_st.freeBytes = (double)freeBytes;
  nxl_st.largestFree = (double)largest;
  nxl_st.peak = (double)nxl_peak;
  nxl_st.maxRequest = (double)nxl_maxRequest;
  nxl_st.room = (nxl_top && nxl_low > limit) ? (double)(nxl_low - limit) : 0.0;
  nxl_st.blocks = (int)nxl_blocks;
  nxl_st.spans = (int)nxl_spanCount;
  nxl_st.fallbacks = (int)nxl_fallbacks;
  nxl_st.rescues = (int)nxl_rescues;
  if (resetPeak)
  {
    nxl_peak = nxl_used;
    nxl_maxRequest = 0;
  }
  __malloc_unlock(_REENT);
}

} // extern "C"
')
#end
class NXLargeHeap
{
  /**
   * One line for [HEAP] logs: region size, blocks in use, free spans (largest), room to grow below, peak use and
   * largest request since the last reset, large requests newlib had to serve and small ones the region rescued.
   * @param resetPeak start a new peak/largest-request window (memory budget per song or week).
   */
  public static function describe(resetPeak:Bool = false):String
  {
    #if (switch && cpp && !nx_legacy_heap)
    untyped __cpp__('nxl_readStats({0} ? 1 : 0)', resetPeak);
    var mb = (x:Float) -> Math.round(x / 104857.6) / 10;
    var region:Float = untyped __cpp__('nxl_st.regionBytes');
    var used:Float = untyped __cpp__('nxl_st.used');
    var freeBytes:Float = untyped __cpp__('nxl_st.freeBytes');
    var largest:Float = untyped __cpp__('nxl_st.largestFree');
    var peak:Float = untyped __cpp__('nxl_st.peak');
    var maxRequest:Float = untyped __cpp__('nxl_st.maxRequest');
    var room:Float = untyped __cpp__('nxl_st.room');
    var blocks:Int = untyped __cpp__('nxl_st.blocks');
    var spans:Int = untyped __cpp__('nxl_st.spans');
    var fallbacks:Int = untyped __cpp__('nxl_st.fallbacks');
    var rescues:Int = untyped __cpp__('nxl_st.rescues');
    return 'large region ${mb(region)} MB: in use ${mb(used)} MB in $blocks blocks, free ${mb(freeBytes)} MB in $spans spans (largest ${mb(largest)} MB)'
      + ', room below ${mb(room)} MB, peak ${mb(peak)} MB, largest request ${mb(maxRequest)} MB, served by newlib $fallbacks, rescued $rescues';
    #else
    return 'large region off';
    #end
  }

  /**
   * Bytes currently held by large blocks (also counted by NXPerformance.getNativeHeapUsed).
   */
  public static function usedBytes():Float
  {
    #if (switch && cpp && !nx_legacy_heap)
    return untyped __cpp__('(double)nxl_usedBytes()');
    #else
    return 0.0;
    #end
  }
}
