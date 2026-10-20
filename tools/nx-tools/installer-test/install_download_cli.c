/*
 * PC command line around source/nx/installer/nx_install_download.h, used by run_download_test.py.
 *
 *   install_download_cli <manifest> <root>
 *
 * Quick check, then downloads what is missing or broken from raw.githubusercontent.com and prints
 * "state=<n> files=<done>/<total> bytes=<done>/<total> rate=<bytes/s> http=<status> error=<text>".
 */
#include "../../../source/nx/installer/nx_install_download.h"

int main(int argc, char **argv)
{
  nxi_manifest m;
  nxi_check c;
  static nxd_progress p;
  if (argc < 3)
  {
    fprintf(stderr, "usage: %s <manifest> <root>\n", argv[0]);
    return 2;
  }
  if (nxi_manifest_load(argv[1], &m) != 0) return 2;
  memset(&c, 0, sizeof(c));
  nxi_quick_check(&m, argv[2], &c);
  curl_global_init(CURL_GLOBAL_DEFAULT);
  snprintf(p.user_agent, sizeof(p.user_agent), "FunkinNX-installer-test");
  nxd_download(&m, &c, argv[2], &p);
  printf("state=%d files=%zu/%zu bytes=%llu/%llu rate=%.0f http=%ld error=%s\n", p.state, p.files_done, p.files_total,
    (unsigned long long)p.bytes_done, (unsigned long long)p.bytes_total, p.bytes_per_second, p.http_status, p.error);
  curl_global_cleanup();
  nxi_check_free(&c);
  nxi_manifest_free(&m);
  return p.state == NXD_DONE ? 0 : 1;
}
