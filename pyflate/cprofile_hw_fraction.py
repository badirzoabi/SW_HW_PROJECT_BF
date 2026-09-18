#!/usr/bin/env python3
import cProfile
import importlib.util
import io
import os
import pstats
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def main():
    orig_path = os.path.join(HERE, "run_benchmark.py")
    data_path = os.path.join(HERE, "data", "interpreter.tar.bz2")

    with open(data_path, "rb") as f:
        data = f.read()

    mod = load("pyflate_orig", orig_path)

    pr = cProfile.Profile()
    pr.enable()
    field = mod.RBitfield(io.BytesIO(data))
    magic = field.readbits(16)
    assert magic == 0x425a
    out = mod.bzip2_main(field)
    pr.disable()

    print("decoded %d bytes" % len(out))

    stats = pstats.Stats(pr)
    stats.sort_stats("tottime")

    # Print full table by tottime (self time), for inspection.
    print("\n==== FULL PROFILE (by self/tottime) ====")
    stats.print_stats(40)

    # Now compute our own totals bucketed by function name, using tottime
    # (self time, excludes sub-calls) so we don't double count time spent
    # inside a call another one of these functions makes.
    stats_dict = stats.stats  # {(file, line, funcname): (cc, nc, tt, ct, callers)}
    total_tt = sum(v[2] for v in stats_dict.values())

    bitread_names = {"readbits", "needbits", "_more", "snoopbits", "_read", "align", "tell"}
    huffman_names = {"find_next_symbol", "_build_lut", "populate_huffman_symbols",
                      "min_max_bits", "_find_symbol"}

    def bucket_time(names):
        t = 0.0
        for (fn, ln, func), v in stats_dict.items():
            if func in names:
                t += v[2]
        return t

    bitread_tt = bucket_time(bitread_names)
    huffman_tt = bucket_time(huffman_names)
    combined_tt = bitread_tt + huffman_tt

    print("\n==== BUCKETED SELF-TIME (tottime) ====")
    print("total self-time across all functions : %.6f s" % total_tt)
    print("bit-reading (RBitfield.*)             : %.6f s  (%.2f%%)" %
          (bitread_tt, 100.0 * bitread_tt / total_tt))
    print("huffman decode (HuffmanTable.*)       : %.6f s  (%.2f%%)" %
          (huffman_tt, 100.0 * huffman_tt / total_tt))
    print("COMBINED (bit-reading + huffman)       : %.6f s  (%.2f%%)  <- this is f" %
          (combined_tt, 100.0 * combined_tt / total_tt))

    print("\n==== PER-FUNCTION BREAKDOWN (the bucketed functions only) ====")
    rows = []
    for (fn, ln, func), v in stats_dict.items():
        if func in bitread_names or func in huffman_names:
            cc, nc, tt, ct, callers = v
            rows.append((tt, func, nc, ct))
    rows.sort(reverse=True)
    for tt, func, nc, ct in rows:
        print("  %-24s calls=%-8d tottime=%.4fs cumtime=%.4fs (%.2f%% of total)" %
              (func, nc, tt, ct, 100.0 * tt / total_tt))


if __name__ == "__main__":
    main()
