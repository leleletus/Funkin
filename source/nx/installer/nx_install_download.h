/*
 * Downloader of the Switch asset installer: fetches every manifest file that is missing or broken on the SD card
 * from raw.githubusercontent.com, at the exact commit of the manifest, checking size and SHA-256 before a file
 * takes its final name. Plain C on top of nx_install_core.h and libcurl (switch-curl on the console, the system
 * libcurl in the PC tests).
 *
 * Each file is written to "<file>.part" and renamed only after its hash matches, so an interrupted download never
 * leaves a wrong file behind; the next run downloads what is still missing.
 */
#ifndef NX_INSTALL_DOWNLOAD_H
#define NX_INSTALL_DOWNLOAD_H

#include <curl/curl.h>
#include <ctype.h>
#include "nx_install_core.h"

#define NXI_RAW_BASE "https://raw.githubusercontent.com/"
#define NXI_MAX_TRIES 6

enum
{
  NXD_IDLE = 0,
  NXD_RUNNING = 1,
  NXD_DONE = 2,          /* every file is on the SD card and verified */
  NXD_FAILED = 3,        /* stopped: see error / http_status */
  NXD_CANCELLED = 4
};

typedef struct
{
  volatile int state;
  volatile int cancel;
  volatile size_t files_done, files_total;
  volatile uint64_t bytes_done, bytes_total;
  volatile double bytes_per_second;
  volatile int waiting_seconds;  /* > 0 while waiting before a retry (rate limit or network error) */
  volatile long http_status;     /* last HTTP status that stopped or delayed the download */
  char current[NXI_MAX_PATH];    /* file being downloaded */
  char error[256];
  char user_agent[96];
} nxd_progress;

typedef struct
{
  FILE *file;
  nxi_sha256 hash;
  uint64_t written;
  uint64_t expected;
  nxd_progress *progress;
  int too_big;
} nxd_sink;

static size_t nxd_write(char *data, size_t size, size_t count, void *user)
{
  nxd_sink *sink = (nxd_sink *)user;
  size_t n = size * count;
  if (sink->written + n > sink->expected)
  {
    sink->too_big = 1; /* not the official file (an HTML page from a captive portal, for example) */
    return 0;
  }
  if (fwrite(data, 1, n, sink->file) != n) return 0;
  nxi_sha256_update(&sink->hash, data, n);
  sink->written += n;
  sink->progress->bytes_done += n;
  return n;
}

static int nxd_abort_check(void *user, curl_off_t dltotal, curl_off_t dlnow, curl_off_t ultotal, curl_off_t ulnow)
{
  (void)dltotal; (void)dlnow; (void)ultotal; (void)ulnow;
  return ((nxd_progress *)user)->cancel ? 1 : 0;
}

/* Percent-encodes a repository path for the URL (spaces and anything outside the unreserved set; '/' stays). */
static void nxd_url_path(const char *path, char *out, size_t cap)
{
  static const char hex[] = "0123456789ABCDEF";
  size_t o = 0;
  for (; *path && o + 4 < cap; path++)
  {
    unsigned char c = (unsigned char)*path;
    if (isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~' || c == '/') out[o++] = (char)c;
    else
    {
      out[o++] = '%';
      out[o++] = hex[c >> 4];
      out[o++] = hex[c & 15];
    }
  }
  out[o] = 0;
}

static void nxd_mkdirs_for(const char *file)
{
  char dir[NXI_MAX_PATH];
  char *slash;
  snprintf(dir, sizeof(dir), "%s", file);
  slash = strrchr(dir, '/');
  if (!slash) return;
  *slash = 0;
  nxi_mkdirs(dir);
}

static void nxd_sleep(nxd_progress *p, int seconds)
{
  int i;
  for (i = seconds; i > 0 && !p->cancel; i--)
  {
    p->waiting_seconds = i;
#ifdef __SWITCH__
    svcSleepThread(1000000000ULL);
#else
    sleep(1);
#endif
  }
  p->waiting_seconds = 0;
}

static size_t nxd_header(char *line, size_t size, size_t count, void *user)
{
  static const char name[] = "retry-after:";
  size_t n = size * count, i;
  long *retry_after = (long *)user;
  if (n <= 12) return n;
  for (i = 0; i < 12; i++)
    if (tolower((unsigned char)line[i]) != name[i]) return n;
  *retry_after = strtol(line + 12, NULL, 10);
  return n;
}

/*
 * Downloads one file. Returns 0 when it is in place and verified, 1 when it should be retried (network error,
 * rate limit or server error; *wait_seconds says how long to wait), -1 when it cannot succeed (404, wrong bytes).
 */
static int nxd_fetch(CURL *curl, const nxi_manifest *m, const nxi_entry *e, const char *root, nxd_progress *p, int *wait_seconds)
{
  char url[NXI_MAX_PATH * 3 + 128], encoded[NXI_MAX_PATH * 3], dest[NXI_MAX_PATH], part[NXI_MAX_PATH + 8], hex[65];
  uint8_t digest[32];
  nxd_sink sink;
  CURLcode rc;
  long status = 0, retry_after = -1;
  uint64_t before = p->bytes_done;

  nxd_url_path(e->path, encoded, sizeof(encoded));
  snprintf(url, sizeof(url), "%s%s/%s/%s", NXI_RAW_BASE, m->repo, m->commit, encoded);
  nxi_join(dest, root, e->path);
  snprintf(part, sizeof(part), "%s.part", dest);
  nxd_mkdirs_for(dest);

  memset(&sink, 0, sizeof(sink));
  sink.file = fopen(part, "wb");
  if (!sink.file)
  {
    snprintf(p->error, sizeof(p->error), "Can't write %.200s (errno %d)", part, errno);
    return -1;
  }
  sink.expected = e->size;
  sink.progress = p;
  nxi_sha256_init(&sink.hash);

  curl_easy_setopt(curl, CURLOPT_URL, url);
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, nxd_write);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, &sink);
  curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, nxd_header);
  curl_easy_setopt(curl, CURLOPT_HEADERDATA, &retry_after);
  rc = curl_easy_perform(curl);
  curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
  fclose(sink.file);

  if (rc == CURLE_OK && status == 200 && sink.written == e->size)
  {
    nxi_sha256_final(&sink.hash, digest);
    nxi_hex(digest, 32, hex);
    if (strcmp(hex, e->sha256) == 0)
    {
      remove(dest);
      if (rename(part, dest) == 0) return 0;
      snprintf(p->error, sizeof(p->error), "Can't rename %.200s (errno %d)", part, errno);
      remove(part);
      return -1;
    }
    snprintf(p->error, sizeof(p->error), "%.200s doesn't match the official file", e->path);
  }
  remove(part);
  p->bytes_done = before;
  if (p->cancel) return -1;

  if (rc == CURLE_OK)
  {
    p->http_status = status;
    if (status == 404)
    {
      snprintf(p->error, sizeof(p->error), "Not found on GitHub: %.200s", e->path);
      return -1;
    }
    if (status == 429 || status == 403 || status >= 500)
    {
      *wait_seconds = retry_after > 0 ? (int)retry_after : 0;
      snprintf(p->error, sizeof(p->error), "GitHub answered %ld", status);
      return 1;
    }
    if (status == 200) return sink.too_big ? -1 : 1; /* truncated or not the official bytes */
    snprintf(p->error, sizeof(p->error), "GitHub answered %ld for %.200s", status, e->path);
    return -1;
  }
  snprintf(p->error, sizeof(p->error), "%.200s", curl_easy_strerror(rc));
  return 1;
}

/*
 * Downloads every entry whose status in `check` is not OK (after nxi_quick_check). Blocking: call it from a worker
 * thread and read `p` from the UI. On return p->state is NXD_DONE, NXD_FAILED or NXD_CANCELLED.
 */
static void nxd_download(const nxi_manifest *m, const nxi_check *check, const char *root, nxd_progress *p)
{
  CURL *curl;
  size_t i;
  time_t started = time(NULL);
  uint64_t bytes_at_start;

  p->state = NXD_RUNNING;
  p->files_done = 0;
  p->files_total = 0;
  p->bytes_done = 0;
  p->bytes_total = 0;
  p->error[0] = 0;
  for (i = 0; i < m->count; i++)
  {
    if (check->status[i] == NXI_OK || check->status[i] == NXI_REPAIRED) continue;
    p->files_total++;
    p->bytes_total += m->entries[i].size;
  }
  bytes_at_start = p->bytes_done;

  curl = curl_easy_init();
  if (!curl)
  {
    snprintf(p->error, sizeof(p->error), "curl_easy_init failed");
    p->state = NXD_FAILED;
    return;
  }
  curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
  curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 3L);
  curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 15L);
  curl_easy_setopt(curl, CURLOPT_LOW_SPEED_LIMIT, 1024L);
  curl_easy_setopt(curl, CURLOPT_LOW_SPEED_TIME, 30L);
  curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
  curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, nxd_abort_check);
  curl_easy_setopt(curl, CURLOPT_XFERINFODATA, p);
  curl_easy_setopt(curl, CURLOPT_USERAGENT, p->user_agent[0] ? p->user_agent : "FunkinNX-installer");
  curl_easy_setopt(curl, CURLOPT_DNS_CACHE_TIMEOUT, 3600L);
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);

  for (i = 0; i < m->count && !p->cancel; i++)
  {
    const nxi_entry *e = &m->entries[i];
    int tries = 0, backoff = 5; /* network errors: 5, 10, 20, 40, 60 s; rate limits wait what GitHub asks */
    if (check->status[i] == NXI_OK || check->status[i] == NXI_REPAIRED) continue;
    snprintf(p->current, sizeof(p->current), "%s", e->path);
    for (;;)
    {
      int wait = 0, r = nxd_fetch(curl, m, e, root, p, &wait);
      double elapsed = difftime(time(NULL), started);
      if (elapsed > 0) p->bytes_per_second = (double)(p->bytes_done - bytes_at_start) / elapsed;
      if (r == 0) break;
      if (r < 0 || ++tries >= NXI_MAX_TRIES || p->cancel)
      {
        p->state = p->cancel ? NXD_CANCELLED : NXD_FAILED;
        curl_easy_cleanup(curl);
        return;
      }
      if (p->http_status == 429 || p->http_status == 403) nxd_sleep(p, wait > 0 ? (wait > 900 ? 900 : wait) : 60 * tries);
      else nxd_sleep(p, wait > 0 ? (wait > 900 ? 900 : wait) : backoff);
      if (backoff < 60) backoff *= 2;
      if (backoff > 60) backoff = 60;
    }
    p->files_done++;
  }
  curl_easy_cleanup(curl);
  p->current[0] = 0;
  p->state = p->cancel ? NXD_CANCELLED : NXD_DONE;
}

#endif
