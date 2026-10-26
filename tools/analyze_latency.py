"""Evaluate the signal probe from tests/reaper_latency.lua; fail on missing audio."""
import csv
import json
import statistics
import sys
from pathlib import Path

directory = Path(sys.argv[1])
events = json.loads((directory / "events.json").read_text())
blocks = [{k: float(v) for k, v in row.items()} for row in csv.DictReader((directory / "signal.csv").open())]
groups = {}
for event in events:
    candidates = [b for b in blocks if event["time"] <= b["time"] < event["time"] + .55 and b["peak"] > .001]
    hit = next((b for i, b in enumerate(candidates[:-2]) if all(
        abs(x["crossings"] * x["rate"] / x["size"] - event["hz"]) < max(200, event["hz"] * .15)
        for x in candidates[i:i + 3])), None)
    assert hit, f"No signal response: {event}"
    delay = (hit["time"] - event["time"]) * 1000
    groups.setdefault(event["backend"] + " / " + event["field"], []).append(delay)
    if event["backend"] != "SWS":
        assert delay < 50, f"Excessive additional response delay: {delay:.2f} ms ({event})"
report = {key: {"samples": len(values), "median_ms": round(statistics.median(values), 2),
                "max_ms": round(max(values), 2), "values_ms": [round(x, 2) for x in values]}
          for key, values in groups.items()}
(directory / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
