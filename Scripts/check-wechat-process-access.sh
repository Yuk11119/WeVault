#!/bin/bash
# Tests process-read access only; does not read memory, pause WeChat or alter it.
set -euo pipefail
wechat_pid="$(pgrep -x WeChat | head -n 1)"
if [[ -z "$wechat_pid" ]]; then
  echo '请先启动并登录微信。' >&2
  exit 1
fi
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/wevault-process-access.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
cat > "$probe_dir/probe.c" <<'C'
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t result = task_for_pid(mach_task_self(), atoi(argv[1]), &task);
    printf("task_for_pid: %d (%s)\n", result, mach_error_string(result));
    if (result == KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), task);
        puts("Process access available. No memory was read.");
        return 0;
    }
    puts("Process access unavailable. No system settings were changed.");
    return 1;
}
C
/usr/bin/cc "$probe_dir/probe.c" -o "$probe_dir/probe"
if [[ "${1:-}" == "--admin" ]]; then
  echo '仅检查微信进程读取权限；密码由 macOS sudo 在本机终端接收。'
  /usr/bin/sudo -- "$probe_dir/probe" "$wechat_pid"
else
  "$probe_dir/probe" "$wechat_pid"
fi
