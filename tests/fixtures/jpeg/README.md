# JPEG decoder profiles

The six JPEGs contain a 37 × 21 synthetic pattern from `generate.c`. No captured
images are used. They were generated with libjpeg-turbo 3.2.0, integer DCT and
the scalar encoder. The odd frame dimensions exercise incomplete chroma
blocks. Adobe CMYK and YCCK exercise the two four-component input paths.

From this directory, with libjpeg-turbo and pkg-config installed:

```sh
cc -std=c99 generate.c $(pkg-config --cflags --libs libjpeg) -o /tmp/uidiff-generate-jpeg
JSIMD_FORCENONE=1 /tmp/uidiff-generate-jpeg
```

`tests/decode.zig` checks the decoded RGBA8 SHA-256 from
`tests/fixtures/jpeg.zig`. The JPEG fuzzer uses the same encoded inputs.
