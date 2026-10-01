# Frozen serial measurements

Derived from saved subprocess records; all sizes are complete frames.
F, grammar_input, and symbol_bwt are Python references; native is compiled bzip3.
These clocks describe these implementations and are not evidence of a native candidate speedup.
Each retained full decode has three samples after one separately recorded first decode.
Restart samples each include fresh model preparation. First and middle blocks are deterministic, not disk-cold.

## final

| Corpus | Block KiB | Codec | Complete B | vs bzip3 | Decode ms min/median/max | MiB/s | Prep ms | First restart ms | Middle restart ms | Encode s |
|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| freedict-eng-spa | 16 | native | 1,189,002 | +0.00% | 209.880/211.769/214.663 | 37.777 | 0.864 | 1.017 | 1.129 | 0.372 |
| freedict-eng-spa | 64 | native | 899,408 | +0.00% | 184.529/190.126/197.586 | 42.077 | 0.715 | 2.363 | 1.853 | 0.364 |
| freedict-eng-spa | 16 | F | 1,141,270 | -4.01% | 2203.410/2205.798/2229.649 | 3.627 | 0.405 | 5.204 | 5.406 | 27.425 |
| freedict-eng-spa | 64 | F | 888,374 | -1.23% | 2014.260/2018.342/2068.124 | 3.964 | 0.227 | 15.579 | 16.065 | 31.668 |
| freedict-eng-spa | 16 | grammar_input | 849,886 | -28.52% | 849.819/851.441/897.106 | 9.396 | 36.623 | 38.682 | 38.370 | 16.997 |
| freedict-eng-spa | 64 | grammar_input | 835,334 | -7.12% | 854.731/854.867/859.116 | 9.358 | 39.155 | 43.234 | 42.945 | 16.572 |
| freedict-eng-spa | 16 | symbol_bwt | 814,375 | -31.51% | 5089.230/5105.185/5151.435 | 1.567 | 35.653 | 47.326 | 48.678 | 125.322 |
| freedict-eng-spa | 64 | symbol_bwt | 778,935 | -13.39% | 4689.326/4701.965/4828.590 | 1.701 | 38.661 | 69.507 | 75.318 | 107.209 |
| gcide-054 | 16 | native | 2,362,319 | +0.00% | 357.106/358.291/373.603 | 22.328 | 0.978 | 1.332 | 1.899 | 0.734 |
| gcide-054 | 64 | native | 1,905,560 | +0.00% | 319.510/319.522/324.367 | 25.037 | 0.789 | 3.267 | 3.109 | 0.766 |
| gcide-054 | 16 | F | 2,343,433 | -0.80% | 3329.336/3345.133/3357.230 | 2.392 | 0.571 | 6.854 | 7.984 | 24.158 |
| gcide-054 | 64 | F | 1,960,472 | +2.88% | 3082.553/3088.274/3093.373 | 2.590 | 0.293 | 24.117 | 24.810 | 27.010 |
| gcide-054 | 16 | grammar_input | 1,935,401 | -18.07% | 2011.226/2017.706/2036.790 | 3.965 | 36.603 | 40.537 | 40.595 | 26.644 |
| gcide-054 | 64 | grammar_input | 1,924,994 | +1.02% | 2059.194/2073.585/2097.490 | 3.858 | 37.404 | 52.617 | 53.035 | 24.871 |
| gcide-054 | 16 | symbol_bwt | 1,860,752 | -21.23% | 13631.079/14199.461/14323.641 | 0.563 | 37.468 | 58.601 | 62.146 | 260.789 |
| gcide-054 | 64 | symbol_bwt | 1,826,256 | -4.16% | 11501.705/11718.015/11793.419 | 0.683 | 36.334 | 120.412 | 135.943 | 251.665 |
| omw-ja-20 | 16 | native | 1,124,142 | +0.00% | 255.507/256.580/257.944 | 31.179 | 1.106 | 1.900 | 2.379 | 0.555 |
| omw-ja-20 | 64 | native | 674,384 | +0.00% | 184.105/194.066/196.541 | 41.223 | 1.250 | 1.990 | 2.187 | 0.396 |
| omw-ja-20 | 16 | F | 1,085,073 | -3.48% | 2240.839/2248.730/2262.336 | 3.558 | 0.422 | 4.677 | 5.835 | 34.637 |
| omw-ja-20 | 64 | F | 744,565 | +10.41% | 1991.268/1998.348/2003.214 | 4.003 | 0.237 | 16.246 | 16.422 | 39.649 |
| omw-ja-20 | 16 | grammar_input | 1,334,367 | +18.70% | 1368.953/1371.763/1381.134 | 5.832 | 38.625 | 40.531 | 37.991 | 19.675 |
| omw-ja-20 | 64 | grammar_input | 1,337,156 | +98.28% | 1383.724/1392.692/1404.631 | 5.744 | 36.768 | 45.704 | 45.055 | 18.925 |
| omw-ja-20 | 16 | symbol_bwt | 778,911 | -30.71% | 3626.605/3739.220/3824.305 | 2.139 | 35.803 | 42.816 | 48.432 | 98.599 |
| omw-ja-20 | 64 | symbol_bwt | 642,092 | -4.79% | 2960.713/3052.369/3068.613 | 2.621 | 35.923 | 54.440 | 69.732 | 72.439 |

## untouched

| Corpus | Block KiB | Codec | Complete B | vs bzip3 | Decode ms min/median/max | MiB/s | Prep ms | First restart ms | Middle restart ms | Encode s |
|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| freedict-eng-spa | 16 | native | 150,446 | +0.00% | 27.288/27.334/27.357 | 36.584 | 0.781 | 0.862 | 0.857 | 0.052 |
| freedict-eng-spa | 64 | native | 115,160 | +0.00% | 22.682/22.687/23.056 | 44.078 | 0.675 | 2.143 | 1.890 | 0.051 |
| freedict-eng-spa | 16 | F | 147,325 | -2.07% | 282.005/284.572/296.489 | 3.514 | 0.220 | 4.677 | 4.638 | 6.072 |
| freedict-eng-spa | 64 | F | 116,664 | +1.31% | 253.844/255.031/262.145 | 3.921 | 0.159 | 16.761 | 16.272 | 6.767 |
| freedict-eng-spa | 16 | grammar_input | 123,548 | -17.88% | 112.042/113.073/114.149 | 8.844 | 13.413 | 15.395 | 15.094 | 1.596 |
| freedict-eng-spa | 64 | grammar_input | 121,776 | +5.75% | 111.643/112.460/112.733 | 8.892 | 12.995 | 20.558 | 20.209 | 1.579 |
| freedict-eng-spa | 16 | symbol_bwt | 123,840 | -17.68% | 353.614/357.286/370.298 | 2.799 | 14.144 | 19.457 | 19.239 | 9.112 |
| freedict-eng-spa | 64 | symbol_bwt | 119,716 | +3.96% | 340.588/340.955/341.593 | 2.933 | 13.617 | 35.104 | 35.780 | 8.153 |
| gcide-054 | 16 | native | 292,647 | +0.00% | 44.558/44.806/45.372 | 22.319 | 0.921 | 1.400 | 1.280 | 0.094 |
| gcide-054 | 64 | native | 235,103 | +0.00% | 39.641/40.071/40.126 | 24.956 | 0.774 | 3.009 | 3.144 | 0.096 |
| gcide-054 | 16 | F | 290,911 | -0.59% | 420.677/421.987/423.423 | 2.370 | 0.222 | 6.970 | 7.124 | 5.349 |
| gcide-054 | 64 | F | 242,643 | +3.21% | 386.274/387.337/387.820 | 2.582 | 0.184 | 24.182 | 23.862 | 6.027 |
| gcide-054 | 16 | grammar_input | 259,063 | -11.48% | 245.690/246.945/247.701 | 4.049 | 25.663 | 31.400 | 30.411 | 2.745 |
| gcide-054 | 64 | grammar_input | 257,534 | +9.54% | 245.644/249.063/249.488 | 4.015 | 25.641 | 41.788 | 40.883 | 2.544 |
| gcide-054 | 16 | symbol_bwt | 256,645 | -12.30% | 1133.340/1143.039/1167.162 | 0.875 | 27.635 | 46.115 | 45.846 | 26.222 |
| gcide-054 | 64 | symbol_bwt | 251,473 | +6.96% | 1105.220/1125.701/1127.415 | 0.888 | 28.007 | 95.861 | 94.366 | 25.040 |
| omw-ja-20 | 16 | native | 155,112 | +0.00% | 33.718/34.100/34.492 | 29.326 | 0.726 | 1.450 | 1.095 | 0.078 |
| omw-ja-20 | 64 | native | 95,276 | +0.00% | 24.058/24.571/24.753 | 40.698 | 0.925 | 1.665 | 2.245 | 0.057 |
| omw-ja-20 | 16 | F | 147,933 | -4.63% | 282.351/290.712/293.537 | 3.440 | 0.209 | 5.268 | 4.926 | 7.334 |
| omw-ja-20 | 64 | F | 104,273 | +9.44% | 246.937/247.713/250.836 | 4.037 | 0.166 | 15.434 | 16.606 | 8.451 |
| omw-ja-20 | 16 | grammar_input | 129,276 | -16.66% | 99.927/100.087/100.715 | 9.991 | 20.319 | 22.188 | 21.457 | 1.936 |
| omw-ja-20 | 64 | grammar_input | 119,684 | +25.62% | 92.370/92.415/93.765 | 10.821 | 21.496 | 22.714 | 25.301 | 1.766 |
| omw-ja-20 | 16 | symbol_bwt | 109,073 | -29.68% | 301.579/305.833/306.495 | 3.270 | 22.081 | 27.495 | 24.548 | 8.807 |
| omw-ja-20 | 64 | symbol_bwt | 95,942 | +0.70% | 231.419/233.258/234.565 | 4.287 | 20.534 | 30.921 | 36.967 | 6.384 |

## Safety and memory accounting

Process peak RSS includes corpus loading, training, encoding, saving, and decoding; it is not decoder-only memory.
Logical prepared-state estimates omit Python object overhead and must not be presented as measured native scratch.

| Corpus | Lane | Block KiB | Codec | Model B | Whole-process peak RSS | Logical prepared B | Logical initialization B | Grammar expansion B | Native conservative scratch B | First full decode ms |
|---|---|---:|---|---:|---:|---:|---:|---:|---:|---:|
| freedict-eng-spa | final | 16 | native | — | 180043776 bytes | — | — | — | 2,654,274 | 212.726 |
| freedict-eng-spa | final | 64 | native | — | 163659776 bytes | — | — | — | 2,654,274 | 174.475 |
| freedict-eng-spa | final | 16 | F | 528 | 162070528 bytes | — | 2,238,998 | — | — | 2200.637 |
| freedict-eng-spa | final | 64 | F | 528 | 164429824 bytes | — | 2,238,998 | — | — | 2024.533 |
| freedict-eng-spa | final | 16 | grammar_input | 45,656 | 389660672 bytes | — | — | 159,146 | — | 846.174 |
| freedict-eng-spa | final | 64 | grammar_input | 45,289 | 337903616 bytes | — | — | 166,872 | — | 862.353 |
| freedict-eng-spa | final | 16 | symbol_bwt | 45,666 | 428130304 bytes | 425,782 | — | 159,146 | — | 5221.004 |
| freedict-eng-spa | final | 64 | symbol_bwt | 45,299 | 360562688 bytes | 431,684 | — | 166,872 | — | 5136.461 |
| freedict-eng-spa | untouched | 16 | native | — | 122175488 bytes | — | — | — | 2,654,274 | 27.723 |
| freedict-eng-spa | untouched | 64 | native | — | 136855552 bytes | — | — | — | 2,654,274 | 23.350 |
| freedict-eng-spa | untouched | 16 | F | 528 | 135921664 bytes | — | 2,238,998 | — | — | 279.794 |
| freedict-eng-spa | untouched | 64 | F | 528 | 123568128 bytes | — | 2,238,998 | — | — | 259.246 |
| freedict-eng-spa | untouched | 16 | grammar_input | 17,768 | 154632192 bytes | — | — | 54,098 | — | 112.390 |
| freedict-eng-spa | untouched | 64 | grammar_input | 17,589 | 121716736 bytes | — | — | 53,885 | — | 112.121 |
| freedict-eng-spa | untouched | 16 | symbol_bwt | 17,778 | 133464064 bytes | 163,326 | — | 54,098 | — | 377.788 |
| freedict-eng-spa | untouched | 64 | symbol_bwt | 17,599 | 121602048 bytes | 161,641 | — | 53,885 | — | 341.229 |
| gcide-054 | final | 16 | native | — | 224575488 bytes | — | — | — | 2,654,274 | 356.942 |
| gcide-054 | final | 64 | native | — | 171589632 bytes | — | — | — | 2,654,274 | 323.604 |
| gcide-054 | final | 16 | F | 528 | 236584960 bytes | — | 2,238,998 | — | — | 3338.901 |
| gcide-054 | final | 64 | F | 528 | 202326016 bytes | — | 2,238,998 | — | — | 3098.326 |
| gcide-054 | final | 16 | grammar_input | 45,613 | 453165056 bytes | — | — | 73,309 | — | 2007.538 |
| gcide-054 | final | 64 | grammar_input | 45,603 | 429146112 bytes | — | — | 73,368 | — | 2024.306 |
| gcide-054 | final | 16 | symbol_bwt | 45,623 | 496680960 bytes | 341,865 | — | 73,309 | — | 12996.705 |
| gcide-054 | final | 64 | symbol_bwt | 45,613 | 421363712 bytes | 341,764 | — | 73,368 | — | 11723.173 |
| gcide-054 | untouched | 16 | native | — | 159924224 bytes | — | — | — | 2,654,274 | 45.697 |
| gcide-054 | untouched | 64 | native | — | 178651136 bytes | — | — | — | 2,654,274 | 41.581 |
| gcide-054 | untouched | 16 | F | 528 | 152961024 bytes | — | 2,238,998 | — | — | 417.284 |
| gcide-054 | untouched | 64 | F | 528 | 161710080 bytes | — | 2,238,998 | — | — | 387.772 |
| gcide-054 | untouched | 16 | grammar_input | 33,361 | 217645056 bytes | — | — | 53,276 | — | 249.574 |
| gcide-054 | untouched | 64 | grammar_input | 33,279 | 164528128 bytes | — | — | 52,292 | — | 255.461 |
| gcide-054 | untouched | 16 | symbol_bwt | 33,371 | 193855488 bytes | 252,680 | — | 53,276 | — | 1131.997 |
| gcide-054 | untouched | 64 | symbol_bwt | 33,289 | 154124288 bytes | 251,056 | — | 52,292 | — | 1143.000 |
| omw-ja-20 | final | 16 | native | — | 268910592 bytes | — | — | — | 2,654,274 | 255.460 |
| omw-ja-20 | final | 64 | native | — | 292831232 bytes | — | — | — | 2,654,274 | 197.835 |
| omw-ja-20 | final | 16 | F | 528 | 273612800 bytes | — | 2,238,998 | — | — | 2262.375 |
| omw-ja-20 | final | 64 | F | 528 | 259571712 bytes | — | 2,238,998 | — | — | 2003.668 |
| omw-ja-20 | final | 16 | grammar_input | 45,926 | 459603968 bytes | — | — | 92,687 | — | 1368.709 |
| omw-ja-20 | final | 64 | grammar_input | 45,573 | 407289856 bytes | — | — | 87,493 | — | 1397.386 |
| omw-ja-20 | final | 16 | symbol_bwt | 45,936 | 479625216 bytes | 344,411 | — | 92,687 | — | 4303.362 |
| omw-ja-20 | final | 64 | symbol_bwt | 45,583 | 394543104 bytes | 336,657 | — | 87,493 | — | 2890.935 |
| omw-ja-20 | untouched | 16 | native | — | 261849088 bytes | — | — | — | 2,654,274 | 34.550 |
| omw-ja-20 | untouched | 64 | native | — | 287162368 bytes | — | — | — | 2,654,274 | 25.338 |
| omw-ja-20 | untouched | 16 | F | 528 | 309428224 bytes | — | 2,238,998 | — | — | 290.667 |
| omw-ja-20 | untouched | 64 | F | 528 | 333758464 bytes | — | 2,238,998 | — | — | 254.385 |
| omw-ja-20 | untouched | 16 | grammar_input | 31,828 | 259424256 bytes | — | — | 87,186 | — | 100.721 |
| omw-ja-20 | untouched | 64 | grammar_input | 29,935 | 259080192 bytes | — | — | 80,554 | — | 94.328 |
| omw-ja-20 | untouched | 16 | symbol_bwt | 31,838 | 268926976 bytes | 247,038 | — | 87,186 | — | 303.862 |
| omw-ja-20 | untouched | 64 | symbol_bwt | 29,945 | 263569408 bytes | 229,878 | — | 80,554 | — | 235.604 |
