#include <stdio.h>
#include <vorbis/vorbisfile.h>
/* Mirrors lime OGG::Decode: buffer = ov_pcm_total * channels * 2, then ov_read until EOF.
 * Prints "OVERFLOW declared decoded extra" when ov_read returns more bytes than were allocated. */
int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    OggVorbis_File vf;
    if (ov_fopen(argv[i], &vf) != 0) { printf("ERROR %s\n", argv[i]); continue; }
    vorbis_info *vi = ov_info(&vf, -1);
    long long declared = (long long)ov_pcm_total(&vf, -1) * vi->channels * 2;
    char buf[4096]; int bs; long n; long long total = 0;
    while ((n = ov_read(&vf, buf, sizeof buf, 0, 2, 1, &bs)) > 0) total += n;
    printf("%s %lld %lld %lld\n", (total > declared) ? "OVERFLOW" : "ok", declared, total, total - declared);
    fflush(stdout);
    ov_clear(&vf);
  }
  return 0;
}
