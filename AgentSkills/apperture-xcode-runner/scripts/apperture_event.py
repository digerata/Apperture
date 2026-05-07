#!/usr/bin/env python3
import argparse
import json
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path


EVENT_DIR = Path.home() / "Library" / "Application Support" / "Apperture" / "AgentEvents"


def optional_int(value):
    if value is None or value == "":
        return None
    return int(value)


def main():
    parser = argparse.ArgumentParser(description="Write an Apperture developer activity event.")
    parser.add_argument("kind")
    parser.add_argument("--status")
    parser.add_argument("--message")
    parser.add_argument("--scheme")
    parser.add_argument("--destination")
    parser.add_argument("--project-root", default=os.getcwd())
    parser.add_argument("--result-bundle-path")
    parser.add_argument("--result-stream-path")
    parser.add_argument("--platform")
    parser.add_argument("--simulator-udid")
    parser.add_argument("--bundle-id")
    parser.add_argument("--app-path")
    parser.add_argument("--pid", type=optional_int)
    parser.add_argument("--warning-count", type=optional_int)
    parser.add_argument("--error-count", type=optional_int)
    parser.add_argument("--event-dir", default=str(EVENT_DIR))
    args = parser.parse_args()

    event = {
        "id": str(uuid.uuid4()),
        "version": 1,
        "kind": args.kind,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "projectRoot": args.project_root,
    }

    optional_fields = {
        "status": args.status,
        "message": args.message,
        "scheme": args.scheme,
        "destination": args.destination,
        "resultBundlePath": args.result_bundle_path,
        "resultStreamPath": args.result_stream_path,
        "platform": args.platform,
        "simulatorUDID": args.simulator_udid,
        "bundleID": args.bundle_id,
        "appPath": args.app_path,
        "pid": args.pid,
        "warningCount": args.warning_count,
        "errorCount": args.error_count,
    }

    event.update({key: value for key, value in optional_fields.items() if value is not None})

    event_dir = Path(args.event_dir).expanduser()
    event_dir.mkdir(parents=True, exist_ok=True)
    event_path = event_dir / f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')}-{event['id']}.json"
    temporary_path = event_path.with_suffix(".json.tmp")
    temporary_path.write_text(json.dumps(event, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary_path.replace(event_path)
    print(event_path)


if __name__ == "__main__":
    main()
