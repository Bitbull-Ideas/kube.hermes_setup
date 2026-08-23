#!/usr/bin/env python3
"""
Graylog REST API client covering the three "Search and Aggregation" MCP
tools described at:
https://go2docs.graylog.org/current/setting_up_graylog/model_context_protocol__mcp__tools.htm

  search_messages    -> Views Search API, search_type "messages"
  aggregate_messages -> Views Search API, search_type "pivot"
  list_fields        -> GET /api/views/fields

Auth: Graylog personal API token used as HTTP Basic username, literal
string "token" as the password (see REST API Access Tokens doc).

Env vars (auto-loaded from /opt/data/.env if not already exported --
override the file path with GRAYLOG_ENV_FILE):
  GRAYLOG_URL              Base URL, e.g. https://graylog.example.com
  GRAYLOG_API_TOKEN        Personal API token (the "username" half of basic auth)
  GRAYLOG_URL_SSL_VERIFY   "False"/"0"/"no" to skip TLS verification (self-signed
                           lab certs); defaults to verifying if unset/unrecognized.

Usage:
  python3 graylog_query.py fields
  python3 graylog_query.py search --query 'sshd AND error' --range 3600 \
      --fields timestamp,source,message --limit 20
  python3 graylog_query.py aggregate --query '*' --range 3600 \
      --group-field source --metric count --limit 10
  python3 graylog_query.py aggregate --query '*' --range 3600 \
      --group-field source --metric avg --metric-field gl2_processing_duration_ms --limit 10
  python3 graylog_query.py trend --query 'level:<=3' --range 3600 --split-field source

Notes:
  - timerange: --range SECONDS (relative) or --from ISO8601 --to ISO8601 (absolute)
  - searches ALL streams by default; pass --stream ID1,ID2 to scope narrower
  - metric one of: count, avg, min, max, sum, card (cardinality), stddev, percentile
  - percentile requires --percentile N (e.g. 95)
"""
import argparse
import json
import os
import sys
import time
import urllib3
import requests

DEFAULT_ENV_FILE = "/opt/data/.env"


def _strip_quotes(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
        return v[1:-1]
    return v


def _load_env_file(path):
    """Minimal .env parser (KEY=VALUE per line, '#' comments, optional quotes).
    Never overrides variables already present in os.environ."""
    if not os.path.isfile(path):
        return
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                key = key.strip()
                if key and key not in os.environ:
                    os.environ[key] = _strip_quotes(val)
    except OSError:
        pass


def _ssl_verify_from_env():
    raw = os.environ.get("GRAYLOG_URL_SSL_VERIFY", "true").strip().strip("'\"")
    return raw.lower() not in ("false", "0", "no", "off")


def get_session():
    _load_env_file(os.environ.get("GRAYLOG_ENV_FILE", DEFAULT_ENV_FILE))

    base = os.environ.get("GRAYLOG_URL", "").rstrip("/")
    token = os.environ.get("GRAYLOG_API_TOKEN")
    if not base or not token:
        sys.exit(
            "GRAYLOG_URL / GRAYLOG_API_TOKEN not set and not found in "
            f"{os.environ.get('GRAYLOG_ENV_FILE', DEFAULT_ENV_FILE)}.\n"
            "Add to that .env file:\n"
            "  GRAYLOG_API_TOKEN=<personal API token>\n"
            "  GRAYLOG_URL='https://<graylog-host>'\n"
            "  GRAYLOG_URL_SSL_VERIFY=False   # only for self-signed lab certs\n"
            "See https://go2docs.graylog.org/current/setting_up_graylog/rest_api_access_tokens.htm "
            "for creating a token."
        )
    verify = _ssl_verify_from_env()
    if not verify:
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    s = requests.Session()
    s.auth = (token, "token")
    s.verify = verify
    s.headers.update({
        "Accept": "application/json",
        "Content-Type": "application/json",
        "X-Requested-By": "graylog-api-skill",  # required CSRF header for POST/PUT/DELETE
    })
    return s, base


def build_timerange(args):
    if args.from_ts and args.to_ts:
        return {"type": "absolute", "from": args.from_ts, "to": args.to_ts}
    return {"type": "relative", "range": args.range}


def run_search(s, base, body, timeout_s=30):
    """POST /views/search -> POST .../execute -> poll GET /views/search/status/{job_id}."""
    r = s.post(f"{base}/api/views/search", data=json.dumps(body))
    r.raise_for_status()
    search_id = r.json()["id"]

    r = s.post(f"{base}/api/views/search/{search_id}/execute")
    r.raise_for_status()
    job_id = r.json()["id"]

    deadline = time.time() + timeout_s
    while time.time() < deadline:
        r = s.get(f"{base}/api/views/search/status/{job_id}")
        r.raise_for_status()
        data = r.json()
        if data.get("execution", {}).get("done"):
            return data
        time.sleep(0.5)
    sys.exit(f"Search job {job_id} did not complete within {timeout_s}s")


def cmd_fields(args):
    s, base = get_session()
    r = s.get(f"{base}/api/views/fields")
    r.raise_for_status()
    fields = r.json()
    if args.filter:
        fields = [f for f in fields if args.filter.lower() in f["name"].lower()]
    print(json.dumps(fields, indent=2))


def cmd_search(args):
    s, base = get_session()
    search_type = {
        "type": "messages",
        "id": "msg1",
        "limit": 1 if args.count_only else args.limit,
        "offset": args.offset,
        "fields": args.fields.split(",") if args.fields else [],
    }
    if args.stream:
        search_type["streams"] = [x.strip() for x in args.stream.split(",") if x.strip()]

    body = {
        "queries": [{
            "query": {"type": "elasticsearch", "query_string": args.query},
            "timerange": build_timerange(args),
            "search_types": [search_type],
        }]
    }
    data = run_search(s, base, body)
    for _, qres in data.get("results", {}).items():
        for _, st in qres.get("search_types", {}).items():
            out = {
                "total_results": st.get("total_results"),
                "effective_timerange": st.get("effective_timerange"),
            }
            if not args.count_only:
                out["messages"] = [m.get("message", {}) for m in st.get("messages", [])]
            print(json.dumps(out, indent=2))


def cmd_aggregate(args):
    s, base = get_session()
    series = {"type": args.metric, "id": f"{args.metric}()"}
    if args.metric != "count":
        if not args.metric_field:
            sys.exit(f"--metric-field is required for metric '{args.metric}'")
        series["field"] = args.metric_field
        series["id"] = f"{args.metric}({args.metric_field})"
    if args.metric == "percentile":
        if not args.percentile:
            sys.exit("--percentile N is required for metric 'percentile'")
        series["percentile"] = args.percentile
        series["id"] = f"percentile({args.metric_field},{args.percentile})"

    pivot = {
        "type": "pivot",
        "id": "agg1",
        "row_groups": [{"type": "values", "field": args.group_field, "limit": args.limit}],
        "series": [series],
        "rollup": True,
    }
    if args.stream:
        pivot["streams"] = [x.strip() for x in args.stream.split(",") if x.strip()]

    body = {
        "queries": [{
            "query": {"type": "elasticsearch", "query_string": args.query},
            "timerange": build_timerange(args),
            "search_types": [pivot],
        }]
    }
    data = run_search(s, base, body)
    for _, qres in data.get("results", {}).items():
        for _, st in qres.get("search_types", {}).items():
            rows = []
            for row in st.get("rows", []):
                if row.get("source") != "leaf":
                    continue
                key = row.get("key", [])
                for v in row.get("values", []):
                    rows.append({"group": key, "metric": v.get("key"), "value": v.get("value")})
            print(json.dumps(rows, indent=2))


def cmd_trend(args):
    """Time-bucketed aggregation (date histogram), optionally split into columns
    by a second field -- good for spotting error spikes / burst patterns."""
    s, base = get_session()
    pivot = {
        "type": "pivot",
        "id": "trend1",
        "row_groups": [{"type": "time", "field": "timestamp",
                         "interval": {"type": "auto", "scaling": 1.0}}],
        "series": [{"type": "count", "id": "count()"}],
        "rollup": True,
    }
    if args.split_field:
        pivot["column_groups"] = [{"type": "values", "field": args.split_field, "limit": args.limit}]
    if args.stream:
        pivot["streams"] = [x.strip() for x in args.stream.split(",") if x.strip()]

    body = {
        "queries": [{
            "query": {"type": "elasticsearch", "query_string": args.query},
            "timerange": build_timerange(args),
            "search_types": [pivot],
        }]
    }
    data = run_search(s, base, body)
    for _, qres in data.get("results", {}).items():
        for _, st in qres.get("search_types", {}).items():
            rows = []
            for row in st.get("rows", []):
                if row.get("source") != "leaf":
                    continue
                bucket = row.get("key", [])
                entry = {"time": bucket[0] if bucket else None, "values": []}
                for v in row.get("values", []):
                    entry["values"].append({"key": v.get("key"), "value": v.get("value")})
                rows.append(entry)
            print(json.dumps(rows, indent=2))


def cmd_events(args):
    """Query triggered Alerts/Events (from configured Event Definitions),
    not raw log messages -- useful to check what Graylog itself already
    flagged before re-deriving the same signal from scratch."""
    s, base = get_session()
    body = {
        "timerange": build_timerange(args),
        "query": args.query if args.query != "*" else "",
        "page": args.page,
        "per_page": args.limit,
        "filter": {"alerts": "only" if args.alerts_only else "include"},
    }
    r = s.post(f"{base}/api/events/search", data=json.dumps(body))
    r.raise_for_status()
    data = r.json()
    print(json.dumps({
        "total_events": data.get("total_events"),
        "events": data.get("events", []),
    }, indent=2))


def cmd_patterns(args):
    """Client-side message-shape clustering: fetch messages, normalize out
    numbers/UUIDs/IPs/hex, and count how many raw messages collapse into
    each template -- a lightweight stand-in for Graylog Illuminate's log
    pattern detection (which needs an enterprise license)."""
    import re as _re
    s, base = get_session()
    search_type = {
        "type": "messages",
        "id": "pat1",
        "limit": args.limit,
        "offset": 0,
        "fields": ["message"],
    }
    if args.stream:
        search_type["streams"] = [x.strip() for x in args.stream.split(",") if x.strip()]
    body = {
        "queries": [{
            "query": {"type": "elasticsearch", "query_string": args.query},
            "timerange": build_timerange(args),
            "search_types": [search_type],
        }]
    }
    data = run_search(s, base, body)
    messages = []
    for _, qres in data.get("results", {}).items():
        for _, st in qres.get("search_types", {}).items():
            messages = [m.get("message", {}).get("message", "") for m in st.get("messages", [])]

    def normalize(msg):
        t = msg
        t = _re.sub(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b", "<UUID>", t)
        t = _re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "<IP>", t)
        t = _re.sub(r"\b0x[0-9a-fA-F]+\b", "<HEX>", t)
        t = _re.sub(r"\b[0-9a-fA-F]{16,}\b", "<HEX>", t)
        t = _re.sub(r"\b\d+\b", "<NUM>", t)
        t = _re.sub(r"\s+", " ", t).strip()
        return t

    clusters = {}
    for msg in messages:
        key = normalize(msg)
        c = clusters.setdefault(key, {"count": 0, "example": msg})
        c["count"] += 1
    ranked = sorted(clusters.items(), key=lambda kv: kv[1]["count"], reverse=True)
    out = [{"template": k, "count": v["count"], "example": v["example"]} for k, v in ranked[: args.top]]
    print(json.dumps({"sampled_messages": len(messages), "distinct_patterns": len(clusters), "top_patterns": out}, indent=2))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    pf = sub.add_parser("fields", help="list_fields equivalent")
    pf.add_argument("--filter", help="substring filter on field name")
    pf.set_defaults(func=cmd_fields)

    def add_common(sp):
        sp.add_argument("--query", default="*", help="Lucene query string")
        sp.add_argument("--range", type=int, default=300, help="relative range in seconds (default 300)")
        sp.add_argument("--from", dest="from_ts", help="absolute ISO-8601 start (pairs with --to)")
        sp.add_argument("--to", dest="to_ts", help="absolute ISO-8601 end (pairs with --from)")
        sp.add_argument("--stream", help="comma-separated stream IDs; default = all streams")
        sp.add_argument("--limit", type=int, default=10)

    pm = sub.add_parser("search", help="search_messages equivalent")
    add_common(pm)
    pm.add_argument("--fields", help="comma-separated field names to return")
    pm.add_argument("--offset", type=int, default=0)
    pm.add_argument("--count-only", action="store_true",
                     help="skip fetching message bodies; just report total_results (cheap existence/volume check)")
    pm.set_defaults(func=cmd_search)

    pa = sub.add_parser("aggregate", help="aggregate_messages equivalent")
    add_common(pa)
    pa.add_argument("--group-field", required=True, help="field to group rows by")
    pa.add_argument("--metric", default="count",
                     choices=["count", "avg", "min", "max", "sum", "card", "stddev", "percentile"])
    pa.add_argument("--metric-field", help="field the metric is computed over (not needed for count)")
    pa.add_argument("--percentile", type=int, help="percentile value, e.g. 95 (metric=percentile only)")
    pa.set_defaults(func=cmd_aggregate)

    pt = sub.add_parser("trend", help="time-bucketed count, optionally split by a field")
    add_common(pt)
    pt.add_argument("--split-field", help="optional field to split columns by (e.g. level, source)")
    pt.set_defaults(func=cmd_trend)

    pe = sub.add_parser("events", help="query triggered Graylog Alerts/Events (not raw messages)")
    add_common(pe)
    pe.add_argument("--page", type=int, default=1)
    pe.add_argument("--alerts-only", action="store_true", help="only events that fired an alert (vs all events)")
    pe.set_defaults(func=cmd_events)

    pp = sub.add_parser("patterns", help="cluster sampled messages into common templates (poor-man's log-pattern detection)")
    add_common(pp)
    pp.add_argument("--top", type=int, default=15, help="how many top patterns to print (default 15)")
    pp.set_defaults(func=cmd_patterns)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
