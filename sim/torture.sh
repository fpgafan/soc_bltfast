#!/bin/sh
# torture.sh SEMILLA_INI SEMILLA_FIN [N] - programas aleatorios: emulador vs placa
cd "$(dirname "$0")"
export PATH=/c/riscv/xpack-riscv-none-elf-gcc-15.2.0-1/bin:$PATH
B=build/torture
dd if=/dev/zero of=$B/vacio.img bs=512 count=64 2>/dev/null
for s in $(seq $1 $2); do
  python rvtorture.py $s $B/t$s.S --n ${3:-20000} || exit 1
  riscv-none-elf-gcc -march=rv32im_zicsr -mabi=ilp32 -nostdlib -nostartfiles -T ../sw/lib/app.ld \
      -Wl,--no-warn-rwx-segments $B/t$s.S -o $B/t$s.elf || exit 1
  riscv-none-elf-objcopy -O binary $B/t$s.elf $B/t$s.bin
  exp=$(node ../tools/socemu.js $B/t$s.bin $B/vacio.img --frames 100000 --out $B 2>/dev/null | grep -a "^SIG" | tr -d '\r')
  got=$(PYTHONIOENCODING=utf-8 timeout 15 python ../tools/load.py $B/t$s.bin --port ${PORT:-COM4} --term 2>/dev/null | grep -a -o -m1 "SIG [0-9a-f]* [0-9a-f]*" | tr -d '\r')
  if [ "$exp" = "$got" ]; then echo "semilla $s: ok ($exp)"; else echo "semilla $s: DISTINTO emulador='$exp' placa='$got'"; fi
done
