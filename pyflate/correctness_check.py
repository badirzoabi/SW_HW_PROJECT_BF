#!/usr/bin/env python3
import hashlib
import importlib.util
import io
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def run(mod, data, wrap_as_file):
    t0 = time.perf_counter()
    field = mod.RBitfield(io.BytesIO(data) if wrap_as_file else data)
    magic = field.readbits(16)
    if magic == 0x1f8b:
        out = mod.gzip_main(field)
    elif magic == 0x425a:
        out = mod.bzip2_main(field)
    else:
        raise Exception("bad magic")
    dt = time.perf_counter() - t0
    return out, dt


def main():
    orig_path = os.path.join(HERE, "orig", "run_benchmark.py")
    opt_path = os.path.join(HERE, "opt", "run_benchmark.py")
    data_path = os.path.join(HERE, "orig", "data", "interpreter.tar.bz2")

    with open(data_path, "rb") as f:
        data = f.read()

    orig_mod = load("pyflate_orig", orig_path)
    opt_mod = load("pyflate_opt", opt_path)

    out_orig, dt_orig = run(orig_mod, data, wrap_as_file=True)
    out_opt, dt_opt = run(opt_mod, data, wrap_as_file=False)

    print("orig: %d bytes, %.3fs, md5=%s" % (
        len(out_orig), dt_orig, hashlib.md5(out_orig).hexdigest()))
    print("opt : %d bytes, %.3fs, md5=%s" % (
        len(out_opt), dt_opt, hashlib.md5(out_opt).hexdigest()))

    if out_orig == out_opt:
        print("CORRECTNESS: PASS (byte-identical output)")
    else:
        print("CORRECTNESS: FAIL (output differs)")
        sys.exit(1)

    if dt_orig > 0:
        print("single-decode speedup: %.2fx" % (dt_orig / dt_opt))


if __name__ == "__main__":
    main()
