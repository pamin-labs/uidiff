# JPEG decoder profiles

The six JPEGs contain a 37 × 21 synthetic pattern from `generate.c`. No captured
images are used. The pinned libjpeg-turbo encoder uses integer DCT and scalar
kernels. The odd frame dimensions exercise incomplete chroma blocks. Adobe
CMYK and YCCK exercise the two four-component input paths.

Run `zig build jpeg-fixtures` from the repository root to regenerate them.
`zig build test` compares the committed bytes with a fresh generation.

`tests/decode.zig` checks the decoded RGBA8 SHA-256 from
`tests/fixtures/jpeg.zig`. The JPEG fuzzer uses the same encoded inputs.
