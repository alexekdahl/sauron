import sys
import re
import pandas as pd
import plotly.express as px

# If a file path is provided as an argument, open that file.
# Otherwise, if data is piped via stdin, use that.
if len(sys.argv) > 1:
    try:
        log_source = open(sys.argv[1], "r")
    except Exception as e:
        print("Error opening file:", e)
        sys.exit(1)
else:
    # Check if stdin is connected to a pipe.
    if sys.stdin.isatty():
        print(
            "Usage: Provide a log file path as an argument or pipe log data to stdin."
        )
        sys.exit(1)
    else:
        log_source = sys.stdin

pattern = (
    r"PID:\s*(\d+)\s*\|\s*"
    r"Name:\s*([\w_]+)\s*\|\s*"
    r"State:\s*([\w\s\(\)-]+)\s*\|\s*"
    r"Threads:\s*(\d+)\s*\|\s*"
    r"RSS \(MB\):\s*([\d\.]+)\s*\|\s*"
    r"VSZ \(MB\):\s*([\d\.]+)\s*\|\s*"
    r"CPU \(%\):\s*([\d\.]+)\s*\|\s*"
    r"Uptime \(sec\):\s*([\d\.]+)\s*\|\s*"
    r"Last Checked:\s*([\d\-\:T\.Z]+)"
)

data = []

# Process each line from the log source
for line in log_source:
    line = line.strip()
    if not line:
        continue  # Skip empty lines
    match = re.match(pattern, line)
    if match:
        (
            pid,
            name,
            state,
            threads,
            rss,
            vsz,
            cpu,
            uptime,
            last_checked,
        ) = match.groups()
        data.append(
            {
                "PID": int(pid),
                "Name": name,
                "State": state.strip(),
                "Threads": int(threads),
                "RSS_MB": float(rss),
                "VSZ_MB": float(vsz),
                "CPU_percent": float(cpu),
                "Uptime_sec": float(uptime),
                "Last_Checked": pd.to_datetime(last_checked),
            }
        )
    else:
        print("Line did not match the expected format:", line)

# Close the file if we opened one; if using sys.stdin, no need to close.
if log_source is not sys.stdin:
    log_source.close()

df = pd.DataFrame(data)
df.sort_values(by="Last_Checked", inplace=True)

fig_cpu = px.line(
    df,
    x="Last_Checked",
    y="CPU_percent",
    color="Name",
    markers=True,
    title="CPU Usage Over Time by Process",
)
fig_cpu.update_layout(xaxis_title="Timestamp", yaxis_title="CPU (%)")
fig_cpu.write_html("cpu_usage.html")

fig_rss = px.line(
    df,
    x="Last_Checked",
    y="RSS_MB",
    color="Name",
    markers=True,
    title="RSS Memory (MB) Over Time by Process",
)
fig_rss.update_layout(xaxis_title="Timestamp", yaxis_title="RSS (MB)")
fig_rss.write_html("rss_usage.html")
