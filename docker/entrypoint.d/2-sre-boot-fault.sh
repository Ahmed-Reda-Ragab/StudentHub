#!/bin/sh
# SRE lab: simulate a release that cannot even start.
# Used to practise ECS deployment circuit breaker, Kubernetes CrashLoopBackOff
# and ASG instance-refresh rollback. Scripts in /etc/entrypoint.d are sourced
# by the image entrypoint (POSIX sh); a non-zero exit stops the container.
if [ "${SRE_FAULT_BOOT_FAIL:-false}" = "true" ]; then
    echo "SRE_FAULT_BOOT_FAIL=true -> refusing to start (simulated broken release ${APP_VERSION:-dev})" >&2
    exit 1
fi
