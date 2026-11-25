/* libjpeg uses longjmp for fatal errors. C owns the jump buffer and the
   live setjmp frame. The Zig callback keeps its cleanup state in its caller. */
#include "jpeg.h"
#include <setjmp.h>

struct decode_error {
    struct jpeg_error_mgr manager;
    jmp_buf jump;
};

void uidiff_jpeg_fail(j_common_ptr decoder) {
    struct decode_error *error = (struct decode_error *)decoder->err;
    longjmp(error->jump, 1);
}

static void reject_warning(j_common_ptr decoder, int level) {
    if (level < 0) uidiff_jpeg_fail(decoder);
}

static void reset_errors(j_common_ptr decoder) {
    decoder->err->num_warnings = 0;
    decoder->err->msg_code = 0;
}

int uidiff_jpeg_guard(j_decompress_ptr decoder, uidiff_jpeg_run run, void *context) {
    struct decode_error error = {
        .manager = {
            .error_exit = uidiff_jpeg_fail,
            .emit_message = reject_warning,
            .reset_error_mgr = reset_errors,
        },
    };
    decoder->err = &error.manager;
    int decoded = 0;
    if (setjmp(error.jump) == 0)
        decoded = run(decoder, context) && error.manager.num_warnings == 0;
    /* In 3.2.1 destruction only releases pools and cannot call error_exit. */
    jpeg_destroy_decompress(decoder);
    return decoded;
}
