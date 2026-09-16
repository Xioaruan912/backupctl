#!/usr/bin/env bash
# 运行全部测试
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_FAIL=0
for t in "$DIR"/t*.sh; do
    [[ -f "$t" ]] || continue
    printf '\n########## %s ##########\n' "$(basename "$t")"
    if bash "$t"; then
        :
    else
        TOTAL_FAIL=$((TOTAL_FAIL+1))
    fi
done
printf '\n================================\n'
if (( TOTAL_FAIL == 0 )); then
    printf '\033[32m全部测试通过\033[0m\n'
else
    printf '\033[31m有 %d 个测试文件失败\033[0m\n' "$TOTAL_FAIL"
fi
exit $(( TOTAL_FAIL > 0 ? 1 : 0 ))
