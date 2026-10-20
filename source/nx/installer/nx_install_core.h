/*
 * Core of the Switch asset installer: reads the asset manifest written by tools/nx-tools/gen_asset_manifest.py,
 * checks the official files on the SD card and keeps the install state. Plain C so the same code runs inside the
 * game (included from nx.installer.NXInstallCore) and on the PC test harness (tools/nx-tools/installer-test).
 *
 * Nothing here touches Haxe objects, so every function can run on a worker thread.
 *
 * Manifest (tab separated, "#" header lines):
 *   #nx-assets 1 / #game_version <v> / #repo <owner/name> / #commit <sha>
 *   <path>  <size>  <sha256 hex>  <git blob>  <group core|cutscene>  <text 0|1>
 *
 * State, in <root>/.nx-install/state.txt (written to a temporary file and renamed):
 *   format 1 / commit <sha> / manifest <sha256 of the manifest text> / status complete|partial
 *   files <n> / bytes <n> / verified <unix time of the last full verification>
 */
#ifndef NX_INSTALL_CORE_H
#define NX_INSTALL_CORE_H

#include <dirent.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#ifdef __SWITCH__
#include <switch.h>
#endif

#define NXI_MAX_PATH 768
#define NXI_IO_CHUNK (1024 * 1024)

/* ------------------------------------------------------------------ SHA-256 */

#ifdef __SWITCH__
typedef Sha256Context nxi_sha256;
static void nxi_sha256_init(nxi_sha256 *c) { sha256ContextCreate(c); }
static void nxi_sha256_update(nxi_sha256 *c, const void *d, size_t n) { sha256ContextUpdate(c, d, n); }
static void nxi_sha256_final(nxi_sha256 *c, uint8_t out[32]) { sha256ContextGetHash(c, out); }
#else
typedef struct
{
  uint32_t h[8];
  uint64_t len;
  uint8_t buf[64];
  size_t used;
} nxi_sha256;

static const uint32_t nxi_k[64] = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01,
  0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08,
  0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

#define NXI_ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void nxi_sha256_block(nxi_sha256 *c, const uint8_t *p)
{
  uint32_t w[64], a, b, d, e, f, g, h, cc, t1, t2;
  int i;
  for (i = 0; i < 16; i++)
    w[i] = ((uint32_t)p[i * 4] << 24) | ((uint32_t)p[i * 4 + 1] << 16) | ((uint32_t)p[i * 4 + 2] << 8) | p[i * 4 + 3];
  for (i = 16; i < 64; i++)
  {
    uint32_t s0 = NXI_ROR(w[i - 15], 7) ^ NXI_ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
    uint32_t s1 = NXI_ROR(w[i - 2], 17) ^ NXI_ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  a = c->h[0]; b = c->h[1]; cc = c->h[2]; d = c->h[3]; e = c->h[4]; f = c->h[5]; g = c->h[6]; h = c->h[7];
  for (i = 0; i < 64; i++)
  {
    t1 = h + (NXI_ROR(e, 6) ^ NXI_ROR(e, 11) ^ NXI_ROR(e, 25)) + ((e & f) ^ (~e & g)) + nxi_k[i] + w[i];
    t2 = (NXI_ROR(a, 2) ^ NXI_ROR(a, 13) ^ NXI_ROR(a, 22)) + ((a & b) ^ (a & cc) ^ (b & cc));
    h = g; g = f; f = e; e = d + t1; d = cc; cc = b; b = a; a = t1 + t2;
  }
  c->h[0] += a; c->h[1] += b; c->h[2] += cc; c->h[3] += d; c->h[4] += e; c->h[5] += f; c->h[6] += g; c->h[7] += h;
}

static void nxi_sha256_init(nxi_sha256 *c)
{
  static const uint32_t iv[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
  memcpy(c->h, iv, sizeof(iv));
  c->len = 0;
  c->used = 0;
}

static void nxi_sha256_update(nxi_sha256 *c, const void *data, size_t n)
{
  const uint8_t *p = (const uint8_t *)data;
  c->len += n;
  while (n > 0)
  {
    size_t take = 64 - c->used;
    if (take > n) take = n;
    memcpy(c->buf + c->used, p, take);
    c->used += take;
    p += take;
    n -= take;
    if (c->used == 64)
    {
      nxi_sha256_block(c, c->buf);
      c->used = 0;
    }
  }
}

static void nxi_sha256_final(nxi_sha256 *c, uint8_t out[32])
{
  uint64_t bits = c->len * 8;
  uint8_t pad = 0x80, zero = 0, lenbuf[8];
  int i;
  nxi_sha256_update(c, &pad, 1);
  while (c->used != 56) nxi_sha256_update(c, &zero, 1);
  for (i = 0; i < 8; i++) lenbuf[i] = (uint8_t)(bits >> (56 - i * 8));
  nxi_sha256_update(c, lenbuf, 8);
  for (i = 0; i < 8; i++)
  {
    out[i * 4] = (uint8_t)(c->h[i] >> 24);
    out[i * 4 + 1] = (uint8_t)(c->h[i] >> 16);
    out[i * 4 + 2] = (uint8_t)(c->h[i] >> 8);
    out[i * 4 + 3] = (uint8_t)c->h[i];
  }
}
#endif

static void nxi_hex(const uint8_t *in, size_t n, char *out)
{
  static const char digits[] = "0123456789abcdef";
  size_t i;
  for (i = 0; i < n; i++)
  {
    out[i * 2] = digits[in[i] >> 4];
    out[i * 2 + 1] = digits[in[i] & 15];
  }
  out[n * 2] = 0;
}

/* ------------------------------------------------------------------ manifest */

typedef struct
{
  char *path;       /* path inside the assets repository, '/' separated */
  uint64_t size;
  char sha256[65];  /* lowercase hex */
  char blob[41];    /* git blob id, only for comparing with GitHub */
  uint8_t cutscene; /* group: 0 core, 1 cutscene */
  uint8_t text;     /* 1 when a CRLF copy of the file may be repaired */
} nxi_entry;

typedef struct
{
  char version[32];
  char repo[96];
  char commit[41];
  char manifest_sha256[65];
  nxi_entry *entries;
  size_t count;
  uint64_t total_bytes;
} nxi_manifest;

static int nxi_path_is_safe(const char *p)
{
  size_t n = strlen(p);
  if (n == 0 || n > NXI_MAX_PATH - 64 || p[0] == '/' || strchr(p, '\\') != NULL) return 0;
  if (strcmp(p, "..") == 0 || strncmp(p, "../", 3) == 0 || strstr(p, "/../") != NULL) return 0;
  if (n >= 3 && strcmp(p + n - 3, "/..") == 0) return 0;
  return 1;
}

static void nxi_manifest_free(nxi_manifest *m)
{
  size_t i;
  for (i = 0; i < m->count; i++) free(m->entries[i].path);
  free(m->entries);
  memset(m, 0, sizeof(*m));
}

/* Parses the manifest text. Returns 0 on success, or the 1-based line number of the first bad line. */
static int nxi_manifest_parse(const char *text, size_t len, nxi_manifest *m)
{
  size_t cap = 2048, pos = 0;
  int line_no = 0;
  nxi_sha256 h;
  uint8_t digest[32];
  memset(m, 0, sizeof(*m));
  m->entries = (nxi_entry *)calloc(cap, sizeof(nxi_entry));
  if (!m->entries) return -1;
  nxi_sha256_init(&h);
  nxi_sha256_update(&h, text, len);
  nxi_sha256_final(&h, digest);
  nxi_hex(digest, 32, m->manifest_sha256);

  while (pos < len)
  {
    const char *line = text + pos;
    const char *nl = (const char *)memchr(line, '\n', len - pos);
    size_t ll = nl ? (size_t)(nl - line) : len - pos;
    char buf[NXI_MAX_PATH + 256];
    pos += ll + (nl ? 1 : 0);
    line_no++;
    if (ll == 0) continue;
    if (ll >= sizeof(buf)) goto bad;
    memcpy(buf, line, ll);
    buf[ll] = 0;
    if (buf[ll - 1] == '\r') buf[ll - 1] = 0;
    if (buf[0] == '#')
    {
      if (strncmp(buf, "#game_version ", 14) == 0) snprintf(m->version, sizeof(m->version), "%.31s", buf + 14);
      else if (strncmp(buf, "#repo ", 6) == 0) snprintf(m->repo, sizeof(m->repo), "%.95s", buf + 6);
      else if (strncmp(buf, "#commit ", 8) == 0) snprintf(m->commit, sizeof(m->commit), "%.40s", buf + 8);
      continue;
    }
    {
      char *fields[6];
      int nf = 0;
      char *s = buf, *tab;
      nxi_entry *e;
      while (nf < 6)
      {
        fields[nf++] = s;
        tab = strchr(s, '\t');
        if (!tab) break;
        *tab = 0;
        s = tab + 1;
      }
      if (nf != 6 || strlen(fields[2]) != 64 || strlen(fields[3]) != 40 || !nxi_path_is_safe(fields[0])) goto bad;
      if (m->count == cap)
      {
        nxi_entry *grown = (nxi_entry *)realloc(m->entries, cap * 2 * sizeof(nxi_entry));
        if (!grown) goto bad;
        memset(grown + cap, 0, cap * sizeof(nxi_entry));
        m->entries = grown;
        cap *= 2;
      }
      e = &m->entries[m->count];
      e->path = strdup(fields[0]);
      if (!e->path) goto bad;
      e->size = strtoull(fields[1], NULL, 10);
      memcpy(e->sha256, fields[2], 65);
      memcpy(e->blob, fields[3], 41);
      e->cutscene = strcmp(fields[4], "cutscene") == 0;
      e->text = fields[5][0] == '1';
      m->total_bytes += e->size;
      m->count++;
    }
  }
  if (m->commit[0] == 0 || m->count == 0) return line_no > 0 ? line_no : 1;
  return 0;
bad:
  nxi_manifest_free(m);
  return line_no > 0 ? line_no : 1;
}

static int nxi_manifest_load(const char *file, nxi_manifest *m)
{
  FILE *f = fopen(file, "rb");
  long n;
  char *text;
  int rc;
  memset(m, 0, sizeof(*m));
  if (!f) return -1;
  fseek(f, 0, SEEK_END);
  n = ftell(f);
  fseek(f, 0, SEEK_SET);
  text = (char *)malloc((size_t)n + 1);
  if (!text || fread(text, 1, (size_t)n, f) != (size_t)n)
  {
    fclose(f);
    free(text);
    return -1;
  }
  fclose(f);
  rc = nxi_manifest_parse(text, (size_t)n, m);
  free(text);
  return rc;
}

/* ------------------------------------------------------------------ results */

enum
{
  NXI_OK = 0,
  NXI_MISSING = 1,
  NXI_WRONG_SIZE = 2,
  NXI_WRONG_HASH = 3,
  NXI_REPAIRED = 4, /* text file with CRLF line endings rewritten with the official bytes */
  NXI_UNREADABLE = 5
};

typedef struct
{
  uint8_t *status;    /* one NXI_* value per manifest entry */
  size_t ok, missing, wrong, repaired, unreadable;
  uint64_t bytes_ok, bytes_needed; /* bytes_needed: size of the files that must be downloaded or copied */
  volatile size_t progress;        /* entries processed, readable from another thread */
  volatile int cancel;             /* set from another thread to stop a full verification */
} nxi_check;

static void nxi_check_reset(nxi_check *c, size_t count)
{
  free(c->status);
  memset(c, 0, sizeof(*c));
  c->status = (uint8_t *)calloc(count ? count : 1, 1);
}

static void nxi_check_free(nxi_check *c)
{
  free(c->status);
  memset(c, 0, sizeof(*c));
}

static void nxi_check_count(nxi_check *c, const nxi_manifest *m)
{
  size_t i;
  c->ok = c->missing = c->wrong = c->repaired = c->unreadable = 0;
  c->bytes_ok = c->bytes_needed = 0;
  for (i = 0; i < m->count; i++)
  {
    switch (c->status[i])
    {
      case NXI_OK: c->ok++; c->bytes_ok += m->entries[i].size; break;
      case NXI_REPAIRED: c->repaired++; c->bytes_ok += m->entries[i].size; break;
      case NXI_MISSING: c->missing++; c->bytes_needed += m->entries[i].size; break;
      case NXI_UNREADABLE: c->unreadable++; c->bytes_needed += m->entries[i].size; break;
      default: c->wrong++; c->bytes_needed += m->entries[i].size; break;
    }
  }
}

/* ------------------------------------------------------------------ quick check (names and sizes) */

static void nxi_join(char *out, const char *root, const char *rel)
{
  size_t n = strlen(root);
  snprintf(out, NXI_MAX_PATH, "%s%s%s", root, (n > 0 && root[n - 1] == '/') ? "" : "/", rel);
}

/*
 * Compares the size of every manifest file with the SD card, without reading the files. Files with the right size
 * count as OK, so a changed byte is only found by nxi_full_verify. Returns the number of files that are not OK.
 */
static size_t nxi_quick_check(const nxi_manifest *m, const char *root, nxi_check *c)
{
  size_t i;
  char full[NXI_MAX_PATH];
  struct stat st;
  nxi_check_reset(c, m->count);
  for (i = 0; i < m->count; i++)
  {
    nxi_join(full, root, m->entries[i].path);
    if (stat(full, &st) != 0 || !S_ISREG(st.st_mode)) c->status[i] = NXI_MISSING;
    else if ((uint64_t)st.st_size != m->entries[i].size) c->status[i] = NXI_WRONG_SIZE;
    else c->status[i] = NXI_OK;
    c->progress = i + 1;
  }
  nxi_check_count(c, m);
  return c->missing + c->wrong + c->unreadable;
}

/* ------------------------------------------------------------------ full verification */

static int nxi_hash_file(const char *file, uint8_t *buf, char out_hex[65], int crlf_to_lf, uint64_t *out_size)
{
  FILE *f = fopen(file, "rb");
  nxi_sha256 h;
  uint8_t digest[32];
  size_t n;
  uint64_t total = 0;
  int pending_cr = 0;
  if (!f) return -1;
  nxi_sha256_init(&h);
  while ((n = fread(buf, 1, NXI_IO_CHUNK, f)) > 0)
  {
    if (!crlf_to_lf)
    {
      nxi_sha256_update(&h, buf, n);
      total += n;
      continue;
    }
    {
      size_t i, start = 0;
      for (i = 0; i < n; i++)
      {
        if (pending_cr)
        {
          pending_cr = 0;
          if (buf[i] != '\n')
          {
            nxi_sha256_update(&h, "\r", 1);
            total++;
          }
        }
        if (buf[i] == '\r')
        {
          nxi_sha256_update(&h, buf + start, i - start);
          total += i - start;
          start = i + 1;
          pending_cr = 1;
        }
      }
      nxi_sha256_update(&h, buf + start, n - start);
      total += n - start;
    }
  }
  if (pending_cr)
  {
    nxi_sha256_update(&h, "\r", 1);
    total++;
  }
  fclose(f);
  nxi_sha256_final(&h, digest);
  nxi_hex(digest, 32, out_hex);
  if (out_size) *out_size = total;
  return 0;
}

/* Rewrites a text file with CRLF line endings converted to LF, through a temporary file. */
static int nxi_rewrite_lf(const char *file, uint8_t *buf)
{
  char tmp[NXI_MAX_PATH + 8];
  FILE *in, *out;
  size_t n;
  int pending_cr = 0, ok = 1;
  snprintf(tmp, sizeof(tmp), "%s.part", file);
  in = fopen(file, "rb");
  if (!in) return -1;
  out = fopen(tmp, "wb");
  if (!out)
  {
    fclose(in);
    return -1;
  }
  while (ok && (n = fread(buf, 1, NXI_IO_CHUNK, in)) > 0)
  {
    size_t i;
    for (i = 0; i < n && ok; i++)
    {
      if (pending_cr)
      {
        pending_cr = 0;
        if (buf[i] != '\n' && fputc('\r', out) == EOF) ok = 0;
      }
      if (buf[i] == '\r') pending_cr = 1;
      else if (fputc(buf[i], out) == EOF) ok = 0;
    }
  }
  if (pending_cr && fputc('\r', out) == EOF) ok = 0;
  fclose(in);
  if (fclose(out) != 0) ok = 0;
  if (!ok)
  {
    remove(tmp);
    return -1;
  }
  remove(file);
  return rename(tmp, file);
}

/*
 * Reads and hashes every manifest file. Text files whose bytes only differ by CRLF line endings (a copy made with a
 * Windows tool) are rewritten with the official bytes when repair is set. Returns the number of files that are not OK.
 */
static size_t nxi_full_verify(const nxi_manifest *m, const char *root, nxi_check *c, int repair)
{
  size_t i;
  char full[NXI_MAX_PATH], hex[65];
  struct stat st;
  uint8_t *buf = (uint8_t *)malloc(NXI_IO_CHUNK);
  nxi_check_reset(c, m->count);
  if (!buf) return m->count;
  for (i = 0; i < m->count && !c->cancel; i++)
  {
    const nxi_entry *e = &m->entries[i];
    uint64_t lf_size = 0;
    nxi_join(full, root, e->path);
    c->progress = i;
    if (stat(full, &st) != 0 || !S_ISREG(st.st_mode))
    {
      c->status[i] = NXI_MISSING;
      continue;
    }
    if ((uint64_t)st.st_size == e->size)
    {
      if (nxi_hash_file(full, buf, hex, 0, NULL) != 0) c->status[i] = NXI_UNREADABLE;
      else c->status[i] = strcmp(hex, e->sha256) == 0 ? NXI_OK : NXI_WRONG_HASH;
      if (c->status[i] == NXI_OK || !e->text) continue;
    }
    else if (!e->text)
    {
      c->status[i] = NXI_WRONG_SIZE;
      continue;
    }
    /* Text file with another size or hash: try the CRLF -> LF version. */
    if (nxi_hash_file(full, buf, hex, 1, &lf_size) == 0 && lf_size == e->size && strcmp(hex, e->sha256) == 0)
    {
      if (!repair) c->status[i] = NXI_WRONG_HASH;
      else c->status[i] = nxi_rewrite_lf(full, buf) == 0 ? NXI_REPAIRED : NXI_UNREADABLE;
    }
    else if (c->status[i] != NXI_WRONG_HASH && c->status[i] != NXI_UNREADABLE)
    {
      c->status[i] = (uint64_t)st.st_size == e->size ? NXI_WRONG_HASH : NXI_WRONG_SIZE;
    }
  }
  for (; i < m->count; i++) c->status[i] = NXI_MISSING; /* cancelled: the rest is unknown */
  c->progress = m->count;
  free(buf);
  nxi_check_count(c, m);
  return c->missing + c->wrong + c->unreadable;
}

/* ------------------------------------------------------------------ state */

typedef struct
{
  char commit[41];
  char manifest_sha256[65];
  int complete;
  uint64_t files, bytes;
  int64_t verified; /* unix time of the last full verification, 0 if never */
} nxi_state;

static int nxi_mkdirs(const char *dir)
{
  char tmp[NXI_MAX_PATH];
  size_t i, n;
  snprintf(tmp, sizeof(tmp), "%s", dir);
  n = strlen(tmp);
  for (i = 1; i < n; i++)
  {
    if (tmp[i] != '/' || tmp[i - 1] == ':') continue; /* keep "sdmc:/" intact */
    tmp[i] = 0;
    if (mkdir(tmp, 0777) != 0 && errno != EEXIST) return -1;
    tmp[i] = '/';
  }
  if (mkdir(tmp, 0777) != 0 && errno != EEXIST) return -1;
  return 0;
}

static int nxi_state_read(const char *root, nxi_state *s)
{
  char file[NXI_MAX_PATH], line[256];
  FILE *f;
  memset(s, 0, sizeof(*s));
  nxi_join(file, root, ".nx-install/state.txt");
  f = fopen(file, "rb");
  if (!f) return -1;
  while (fgets(line, sizeof(line), f))
  {
    line[strcspn(line, "\r\n")] = 0;
    if (strncmp(line, "commit ", 7) == 0) snprintf(s->commit, sizeof(s->commit), "%.40s", line + 7);
    else if (strncmp(line, "manifest ", 9) == 0) snprintf(s->manifest_sha256, sizeof(s->manifest_sha256), "%.64s", line + 9);
    else if (strncmp(line, "status ", 7) == 0) s->complete = strcmp(line + 7, "complete") == 0;
    else if (strncmp(line, "files ", 6) == 0) s->files = strtoull(line + 6, NULL, 10);
    else if (strncmp(line, "bytes ", 6) == 0) s->bytes = strtoull(line + 6, NULL, 10);
    else if (strncmp(line, "verified ", 9) == 0) s->verified = strtoll(line + 9, NULL, 10);
  }
  fclose(f);
  return 0;
}

static int nxi_state_write(const char *root, const nxi_state *s)
{
  char dir[NXI_MAX_PATH], file[NXI_MAX_PATH], tmp[NXI_MAX_PATH + 8];
  FILE *f;
  int ok;
  nxi_join(dir, root, ".nx-install");
  if (nxi_mkdirs(dir) != 0) return -1;
  nxi_join(file, root, ".nx-install/state.txt");
  snprintf(tmp, sizeof(tmp), "%s.part", file);
  f = fopen(tmp, "wb");
  if (!f) return -1;
  ok = fprintf(f, "format 1\ncommit %s\nmanifest %s\nstatus %s\nfiles %llu\nbytes %llu\nverified %lld\n", s->commit,
         s->manifest_sha256, s->complete ? "complete" : "partial", (unsigned long long)s->files,
         (unsigned long long)s->bytes, (long long)s->verified) > 0;
  if (fflush(f) != 0) ok = 0;
  fsync(fileno(f));
  if (fclose(f) != 0) ok = 0;
  if (!ok)
  {
    remove(tmp);
    return -1;
  }
  remove(file);
  return rename(tmp, file);
}

/* True when the state says this exact manifest was installed completely. */
static int nxi_state_matches(const nxi_state *s, const nxi_manifest *m)
{
  return s->complete && strcmp(s->commit, m->commit) == 0 && strcmp(s->manifest_sha256, m->manifest_sha256) == 0;
}

#endif
