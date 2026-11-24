                    /* Both ranges fit the current contiguous window.
                       Bulk copies cannot overlap except for repeated patterns. */
                    if (pSrc + counter <= pOut_buf_cur || pOut_buf_cur + counter <= pSrc) {
                        memcpy(pOut_buf_cur, pSrc, counter);
                        pOut_buf_cur += counter;
                        continue;
                    }
                    if (pSrc + 1 == pOut_buf_cur) {
                        memset(pOut_buf_cur, *pSrc, counter);
                        pOut_buf_cur += counter;
                        continue;
                    }
                    if (pSrc < pOut_buf_cur && counter >= 16) {
                        const size_t pitch = pOut_buf_cur - pSrc;
                        if (pitch == 2 || pitch == 4 || pitch == 8) {
                            mz_uint8 pattern[16];
                            for (size_t i = 0; i < sizeof(pattern); i++)
                                pattern[i] = pSrc[i & (pitch - 1)];
                            while (counter >= sizeof(pattern)) {
                                memcpy(pOut_buf_cur, pattern, sizeof(pattern));
                                pOut_buf_cur += sizeof(pattern);
                                counter -= sizeof(pattern);
                            }
                            memcpy(pOut_buf_cur, pattern, counter);
                            pOut_buf_cur += counter;
                            continue;
                        }
                    }
