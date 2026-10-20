/*
 * PC command line around source/nx/installer/nx_install_core.h, used by run_tests.py.
 *
 *   install_core_cli quick  <manifest> <root>
 *   install_core_cli verify <manifest> <root> [repair]
 *   install_core_cli state  <manifest> <root>        # write a complete state, read it back, check it matches
 *
 * Prints "ok=<n> missing=<n> wrong=<n> repaired=<n> unreadable=<n> needed=<bytes>" and one line per bad file.
 */
#include "../../../source/nx/installer/nx_install_core.h"

static const char *status_name(int s)
{
  switch (s)
  {
    case NXI_MISSING: return "missing";
    case NXI_WRONG_SIZE: return "wrong-size";
    case NXI_WRONG_HASH: return "wrong-hash";
    case NXI_REPAIRED: return "repaired";
    case NXI_UNREADABLE: return "unreadable";
    default: return "ok";
  }
}

int main(int argc, char **argv)
{
  nxi_manifest m;
  nxi_check c;
  size_t i;
  int rc;
  if (argc < 4)
  {
    fprintf(stderr, "usage: %s quick|verify|state <manifest> <root> [repair]\n", argv[0]);
    return 2;
  }
  rc = nxi_manifest_load(argv[2], &m);
  if (rc != 0)
  {
    fprintf(stderr, "manifest error at line %d\n", rc);
    return 2;
  }
  memset(&c, 0, sizeof(c));
  if (strcmp(argv[1], "state") == 0)
  {
    nxi_state s, back;
    memset(&s, 0, sizeof(s));
    snprintf(s.commit, sizeof(s.commit), "%s", m.commit);
    snprintf(s.manifest_sha256, sizeof(s.manifest_sha256), "%s", m.manifest_sha256);
    s.complete = 1;
    s.files = m.count;
    s.bytes = m.total_bytes;
    s.verified = (int64_t)time(NULL);
    if (nxi_state_write(argv[3], &s) != 0 || nxi_state_read(argv[3], &back) != 0)
    {
      printf("state io failed\n");
      return 1;
    }
    rc = nxi_state_matches(&back, &m);
    printf("state matches=%d files=%llu bytes=%llu\n", rc, (unsigned long long)back.files, (unsigned long long)back.bytes);
    nxi_manifest_free(&m);
    return rc ? 0 : 1;
  }
  if (strcmp(argv[1], "quick") == 0) nxi_quick_check(&m, argv[3], &c);
  else nxi_full_verify(&m, argv[3], &c, argc > 4 && strcmp(argv[4], "repair") == 0);
  printf("ok=%zu missing=%zu wrong=%zu repaired=%zu unreadable=%zu needed=%llu files=%zu commit=%.9s\n", c.ok, c.missing,
    c.wrong, c.repaired, c.unreadable, (unsigned long long)c.bytes_needed, m.count, m.commit);
  for (i = 0; i < m.count; i++)
    if (c.status[i] != NXI_OK) printf("%s %s\n", status_name(c.status[i]), m.entries[i].path);
  nxi_check_free(&c);
  nxi_manifest_free(&m);
  return 0;
}
