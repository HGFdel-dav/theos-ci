#!/usr/bin/env python3
"""Read ONLY explicitly supplied local MiniSight diagnostic files (stdlib only)."""
import argparse
import datetime as dt
import json
import math
from pathlib import Path
import re
import sys
import uuid

MAX_BYTES = 256 * 1024       # Per-file tail, including a possible partial first line.
MAX_LINE = 8192
MAX_FILES = 32
MAX_EVENTS = 5000
UTC = dt.timezone.utc
FEATURES = {'activity', 'ai', 'ai_test', 'approval', 'assets', 'bubble', 'chat', 'drag', 'front', 'gesture', 'gravity', 'ownership', 'plugin', 'recorder', 'recording', 'runtime', 'screen', 'settings', 'voice'}
STAGES = {'apply', 'begin', 'build', 'callback', 'cancel', 'change', 'click', 'close', 'composer', 'config', 'configure', 'container', 'deadline', 'deliver', 'display', 'editor', 'end', 'entry', 'error', 'finish', 'handle', 'hide', 'identity', 'interruption', 'keyboard', 'layout', 'load', 'network', 'opening', 'parse', 'publish', 'readback', 'ready', 'receive', 'reload', 'reply', 'request', 'response', 'result', 'rotate', 'sample', 'save', 'send', 'send-entry', 'show', 'skip', 'start', 'state', 'status', 'stop', 'visibility'}
RESULTS = {"ok", "failed", "skipped", "cancelled", "pending", "unsupported"}
KEYS = {'active', 'below', 'bytes', 'chars', 'code', 'count', 'domain', 'duration_ms', 'enabled', 'executing', 'field', 'finish', 'generation', 'h', 'http', 'issue', 'keyboard', 'mode', 'present', 'readback', 'reason', 'reasoning', 'renderer', 'request', 'revision', 'roll', 'samples', 'saved', 'sending', 'sequence', 'setting', 'source', 'style', 'valid', 'value', 'version', 'visible', 'w', 'x', 'y'}
STRING_KEYS = set("setting source reason renderer mode style field code domain issue finish version".split())
ALIASES = {"ui_generation": "generation", "rows": "count", "text_len": "chars", "contentlen": "chars", "errorCode": "code", "status": "code", "http": "code"}
IDENT = re.compile(r"[A-Za-z0-9_.-]{1,80}\Z")
LINE = re.compile(r"^(?P<time>\d{4}-\d\d-\d\d[T ]\d\d:\d\d:\d\d\.\d+(?:Z|[+-]\d\d:\d\d)?|\d\d-\d\d \d\d:\d\d:\d\d\.\d+) pid=(?P<pid>\d{1,10}) (?P<body>.*)$")
HEAD = re.compile(r"^(?:client=[A-Fa-f0-9-]{36} )?(chat|settings|runtime|voice|ai|recorder|gravity|activity|screen|front|plugin)\b(?: ([A-Za-z_-]+))?")
PAIRS = re.compile(r"(?:^| )([A-Za-z_]+)=([A-Za-z0-9_./-]+)(?= |$)")


def identifier(value):
    if not isinstance(value, str) or not IDENT.fullmatch(value):
        return False
    low = value.lower()
    return not (low.startswith(("sk-", "sk_", "bearer")) or any(x in low for x in ("apikey", "api_key", "token")))


def request_identifier(value):
    if not isinstance(value, str) or len(value) > 80:
        return None
    parts = re.split(r"[/.]", value)
    if len(parts) not in {1, 2} or (len(parts) == 2 and not re.fullmatch(r"[0-9]{1,15}", parts[1])):
        return None
    try:
        base = str(uuid.UUID(parts[0]))
    except ValueError:
        return None
    return base if len(parts) == 1 else base + "." + parts[1]


def safe_value(key, value):
    if key == "request" and isinstance(value, str):
        return request_identifier(value)
    if isinstance(value, (bool, int, float)):
        return value if abs(value) <= 9007199254740991 and math.isfinite(value) else None
    if not identifier(value):
        return None
    if key in {"request", "revision"}:
        try:
            return str(uuid.UUID(value))
        except (ValueError, AttributeError):
            return None
    return value if key in STRING_KEYS else None


def safe_fields(fields):
    if not isinstance(fields, dict):
        return {}
    out = {}
    for key in KEYS:
        value = safe_value(key, fields.get(key))
        if value is not None:
            out[key] = value
    return out


def parse_time(text, now=None):
    """Old timestamps lack year/timezone: assume local zone, most recent year."""
    now = now or dt.datetime.now().astimezone()
    if re.match(r"^\d\d-\d\d ", text):
        value = dt.datetime.strptime(str(now.year) + "-" + text, "%Y-%m-%d %H:%M:%S.%f").replace(tzinfo=now.tzinfo)
        if value > now + dt.timedelta(days=1):
            value = value.replace(year=value.year - 1)
    else:
        value = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
        if value.tzinfo is None:
            value = value.replace(tzinfo=now.tzinfo)
    return value.astimezone(UTC)


def legacy_event(body):
    match = HEAD.match(body)
    if not match:
        return None
    feature, stage = match.groups()
    stage = stage if stage in STAGES else "status"
    raw = dict(PAIRS.findall(body))
    fields = {}
    for key, value in raw.items():
        key = ALIASES.get(key, key)
        if key not in KEYS:
            continue
        if re.fullmatch(r"-?\d+(?:\.\d+)?", value):
            value = float(value) if "." in value else int(value)
        fields[key] = value
    result = "pending"  # Legacy entry/begin/receive alone never proves success.
    if raw.get("success") == "0" or raw.get("kind") == "error":
        result = "failed"
    elif stage == "cancel" or raw.get("kind") == "cancelled":
        result = "cancelled"
    elif raw.get("success") == "1" or (stage == "display" and raw.get("kind") == "answer"):
        result = "ok"
    elif feature == "ai" and stage == "finish" and "issue" in raw:
        result = "ok" if raw["issue"] == "0" else "failed"
    if stage == "send-entry":
        stage = "send"
    elif feature == "chat" and stage == "handle":
        stage = "reply"
    return {"feature": feature, "stage": stage, "result": result, "fields": safe_fields(fields), "legacy": True}


def parse_line(line, now=None):
    if len(line) > MAX_LINE:
        return None
    match = LINE.match(line.rstrip("\r\n"))
    if not match:
        return None
    try:
        time = parse_time(match["time"], now)
    except (ValueError, OverflowError):
        return None
    body = match["body"]
    metadata = {"pid": int(match["pid"]), "process": "unknown", "runId": "legacy", "seq": None}
    if " event=" in body:
        prefix, payload = body.split(" event=", 1)
        values = dict(PAIRS.findall(prefix))
        metadata["process"] = values.get("process") if identifier(values.get("process")) else "unknown"
        try:
            metadata["runId"] = str(uuid.UUID(values.get("runId", "")))
            seq = int(values.get("seq", ""))
            if not 0 < seq <= 9007199254740991:
                return None
            metadata["seq"] = seq
            event = json.loads(payload)
        except (ValueError, TypeError, RecursionError):
            return None
        if not isinstance(event, dict):
            return None
        feature, stage, result = (event.get(k) for k in ("feature", "stage", "result"))
        if not all(isinstance(x, str) for x in (feature, stage, result)):
            return None
        if feature not in FEATURES or stage not in STAGES or result not in RESULTS:
            return None
        # Reconstruct an allowlisted object: never echo raw payload or file paths.
        event = {"feature": feature, "stage": stage, "result": result, "fields": safe_fields(event.get("fields")), "legacy": event.get("legacy") is True}
        if event["legacy"] and event["stage"] == "send-entry":
            event["stage"] = "send"
        if event["legacy"] and event["feature"] == "chat" and event["stage"] == "handle":
            event["stage"] = "reply"
    else:
        event = legacy_event(body)
        if event is None:
            return None
    return {"time": time.isoformat(timespec="milliseconds").replace("+00:00", "Z"), **metadata, **event}


def bounded_lines(path):
    with path.open("rb") as handle:
        handle.seek(0, 2)
        size = handle.tell()
        start = max(0, size - MAX_BYTES)
        handle.seek(start)
        data = handle.read(MAX_BYTES)
    if start:
        data = data.partition(b"\n")[2]  # Discard possible partial first record.
    return data.decode("utf-8", errors="replace").splitlines()


def load_events(paths, feature=None, since=None, tail=200, now=None):
    events, errors, seen = [], 0, set()
    if len(paths) > MAX_FILES:
        raise ValueError("too_many_files")
    for path in paths:
        try:
            lines = bounded_lines(Path(path))
        except OSError:
            errors += 1
            continue
        for line in lines:
            event = parse_line(line, now=now)
            if event is None or (feature and event["feature"] != feature):
                continue
            if since and parse_time(event["time"]) < since:
                continue
            # Copies of a rotated file can overlap. Per-process runId+seq is unique.
            identity = (event["pid"], event["runId"], event["seq"]) if event["seq"] else json.dumps(event, sort_keys=True)
            if identity not in seen:
                seen.add(identity)
                events.append(event)
    events.sort(key=lambda e: (e["time"], e["pid"], e["runId"], e["seq"] or 0))
    return events[-min(tail, MAX_EVENTS):], errors


def build_report(events, read_errors=0):
    counts, groups = {}, {}
    for event in events:
        feature, stage, result = (event[k] for k in ("feature", "stage", "result"))
        count_key = f"{feature}.{stage}.{result}"
        counts[count_key] = counts.get(count_key, 0) + 1
        if feature not in {"chat", "settings"}:
            continue
        fields = event["fields"]
        if feature == "settings":
            setting = fields.get("setting", fields.get("field", "unknown"))
            revision = fields.get("revision")
            identity = f"setting={setting} revision={revision}" if revision is not None else f"setting={setting} revision=unknown"
        elif fields.get("request") is not None:
            identity = f"request={fields['request']}"
        else:
            identity = f"run={event['runId']} pid={event['pid']} generation={fields.get('generation', 'unknown')}"
        group = groups.setdefault((feature, identity), {"feature": feature, "identity": identity, "stages": {}, "last_time": event["time"]})
        group["stages"][stage] = result
        group["last_time"] = event["time"]
    chains = []
    for group in groups.values():
        stages = group["stages"]
        relevant = ("save", "readback", "publish", "receive", "configure", "apply") if group["feature"] == "settings" else ("send", "reply", "display")
        group["checkpoints"] = {stage: stages.get(stage, "unobserved") for stage in relevant}
        notes = []
        bad = [f"{stage}={result}" for stage, result in stages.items() if result in {"failed", "cancelled", "skipped", "unsupported"}]
        if bad:
            notes.append("已记录状态：" + ", ".join(bad))
        if group["feature"] == "chat":
            if "display" not in stages:
                notes.append("当前窗口未见 display；不能据此判定未发送。")
            if "send" in stages and "reply" not in stages:
                notes.append("已观察 send 阶段，当前窗口未见 reply；请核对同一 request 的后续记录。")
            if "display" in stages and "send" not in stages:
                notes.append("已观察 display，send 可能在当前窗口之外；显示事件不补推发送事件。")
        else:
            if stages.get("save") == "ok" and "receive" not in stages:
                notes.append("已记录 save=ok，当前窗口未见 receive。")
            if "receive" in stages and "configure" not in stages and "apply" not in stages:
                notes.append("已观察 receive，当前窗口未见 configure/apply。")
            if "configure" in stages and "apply" not in stages:
                notes.append("configure 仅证明运行对象已赋值；实际动作、显示或传感器投递另看对应功能事件。")
            if "revision=unknown" in group["identity"]:
                notes.append("缺少 revision，同一设置的各阶段不能确认为同一次修改。")
        if not notes:
            notes.append("已列出可见阶段结果；是否生效仍以对应 apply/display 结果为依据。")
        group["notes"] = notes
        chains.append(group)
    chains.sort(key=lambda c: (c["last_time"], c["feature"], c["identity"]))
    return {"scope": "仅指定文件有界尾部及过滤窗口；未观测不等于未执行。旧时间无年份/时区，按本机时区及最近年份估计。", "read_errors": read_errors, "event_count": len(events), "counts": dict(sorted(counts.items())), "chains": chains, "events": events}


def render_text(report):
    lines = [f"MiniSight 诊断摘要：{report['event_count']} 条；读取失败 {report['read_errors']} 个文件。", report["scope"]]
    if not report["events"]:
        lines.append("当前窗口无可解析事件；不能据此判定功能未执行。")
    for key, count in report["counts"].items():
        lines.append(f"  {key}: {count}")
    for chain in report["chains"]:
        checkpoints = " → ".join(f"{stage}={result}" for stage, result in chain["checkpoints"].items())
        lines.append(f"[{chain['feature']}] {chain['identity']} | {checkpoints}")
        lines.extend("  " + note for note in chain["notes"])
    lines.append("可见事件（已白名单脱敏）：")
    for event in report["events"]:
        fields = json.dumps(event["fields"], ensure_ascii=True, sort_keys=True, separators=(",", ":"))
        seq = event["seq"] if event["seq"] is not None else "legacy"
        lines.append(f"{event['time']} pid={event['pid']} process={event['process']} runId={event['runId']} seq={seq} {event['feature']}.{event['stage']}={event['result']} fields={fields}")
    return "\n".join(lines)


def parse_since(text):
    match = re.fullmatch(r"(\d{1,6})([smhd])", text)
    if match:
        seconds = int(match[1]) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[match[2]]
        return dt.datetime.now(UTC) - dt.timedelta(seconds=seconds)
    return parse_time(text)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", help="Local files only; pass .log.1 rotations explicitly (no device/network access)")
    parser.add_argument("--feature", choices=sorted(FEATURES))
    parser.add_argument("--since", help="ISO-8601 time, or relative 30m/2h/1d (local zone if omitted)")
    parser.add_argument("--tail", type=int, default=200, help="Last matching events after merge/sort, 1..5000 (default 200)")
    parser.add_argument("--json", action="store_true", help="Print sanitized report as JSON")
    args = parser.parse_args(argv)
    if not 1 <= args.tail <= MAX_EVENTS:
        parser.error("--tail must be 1..5000")
    if len(args.paths) > MAX_FILES:
        parser.error("at most 32 local files")
    try:
        since = parse_since(args.since) if args.since else None
    except (ValueError, OverflowError):
        parser.error("invalid --since; expected ISO-8601 or 30m/2h/1d")
    events, errors = load_events(args.paths, feature=args.feature, since=since, tail=args.tail)
    report = build_report(events, errors)
    print(json.dumps(report, ensure_ascii=False, sort_keys=True, indent=2) if args.json else render_text(report))
    return 2 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
