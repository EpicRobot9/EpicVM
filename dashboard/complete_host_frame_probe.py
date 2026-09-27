"""Complete a gaming console only after the host's browser decoded real frames.

Invoked inside the private dashboard container by the trusted host supervisor.
No credentials or pairing data cross stdout.
"""

from __future__ import annotations

import json
import re
import sys

from remote_hosts import ConfiguredVmHostRegistry


PENDING = {"streaming_setup", "setup_failed:streaming", "setup_failed:agent_restart"}
NAME = re.compile(r"^[a-z0-9][a-z0-9._-]{0,62}$")


def pending_jobs(host):
    result = []
    for job in host.provisioning_jobs():
        name = str(job.get("name") or "")
        if (NAME.fullmatch(name) and job.get("profile") == "gaming"
                and job.get("state") in PENDING
                and job.get("gamingCaptureConfigured") is True):
            result.append({"id": str(job.get("id") or ""), "name": name,
                           "routePrefix": str(job.get("consoleRoutePrefix") or f"/vm/{name}--epic-pc/")})
    return result


def valid_metrics(metrics):
    try:
        checks = (("nonblackFraction", .20, 1), ("meanLuma", 12, 252),
                  ("stdDev", 8, 127.5), ("decodedFramesDelta", 3, float("inf")),
                  ("durationMs", 1500, float("inf")))
        return all(low <= float(metrics[key]) <= high for key, low, high in checks)
    except (KeyError, TypeError, ValueError):
        return False


def main():
    host = ConfiguredVmHostRegistry().get("epic-pc")
    if len(sys.argv) == 2 and sys.argv[1] == "list":
        print(json.dumps(pending_jobs(host)))
        return
    if len(sys.argv) != 2 or sys.argv[1] != "complete":
        raise SystemExit(2)
    report = json.load(sys.stdin)
    name, job_id = str(report.get("name") or ""), str(report.get("id") or "")
    metrics = report.get("frameMetrics")
    if not isinstance(metrics, dict) or not valid_metrics(metrics):
        print("frame_evidence_rejected")
        raise SystemExit(1)
    job = next((item for item in pending_jobs(host)
                if item["name"] == name and item["id"] == job_id), None)
    if job is None:
        print("job_not_pending")
        raise SystemExit(1)
    try:
        result = host.console_complete(job_id, route_prefix=job["routePrefix"],
                                       guest_tcp_verified=True, frame_metrics=metrics)
    except Exception as exc:
        print("completion_error:" + str(getattr(exc, "code", type(exc).__name__)))
        raise SystemExit(1) from None
    ready = isinstance(result, dict) and (result.get("job") or {}).get("state") == "ready"
    print("ready" if ready else "not_ready")
    if not ready:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
