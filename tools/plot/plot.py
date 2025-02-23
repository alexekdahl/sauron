import sys
import re
import pandas as pd
import plotly.express as px


def parse_log_line(line, pattern):
    """
    Parse a single log line using the provided regex pattern.
    Returns a dictionary of parsed values if matched, or None otherwise.
    """
    match = re.match(pattern, line)
    if match:
        pid, name, state, threads, rss, vsz, cpu, uptime, last_checked = match.groups()
        return {
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
    else:
        print("Line did not match the expected format:", line)
        return None


def read_log_source():
    """
    Determine the log source:
    - Open the file provided as a command-line argument, or
    - Use sys.stdin if data is being piped.
    Returns a tuple of (log_source, should_close) where should_close indicates
    whether the file should be closed later.
    """
    if len(sys.argv) > 1:
        try:
            return open(sys.argv[1], "r"), True
        except Exception as e:
            print("Error opening file:", e)
            sys.exit(1)
    else:
        if sys.stdin.isatty():
            print(
                "Usage: Provide a log file path as an argument or pipe log data to stdin."
            )
            sys.exit(1)
        else:
            return sys.stdin, False


def process_logs(log_source, pattern):
    """
    Process the log source line by line, parsing each valid log entry.
    Returns a list of dictionaries containing the log data.
    """
    data = []
    for line in log_source:
        line = line.strip()
        if not line:
            continue  # Skip empty lines
        entry = parse_log_line(line, pattern)
        if entry:
            data.append(entry)
    return data


def generate_plots(df):
    """
    Generate and save the CPU usage and RSS memory usage plots as HTML files.
    """
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
        title="Memory (MB) Over Time by Process",
    )
    fig_rss.update_layout(xaxis_title="Timestamp", yaxis_title="MEM (MB)")
    fig_rss.write_html("rss_usage.html")


def main():
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

    log_source, should_close = read_log_source()
    data = process_logs(log_source, pattern)

    if should_close:
        log_source.close()

    if not data:
        print("No valid log entries found.")
        sys.exit(1)

    df = pd.DataFrame(data)
    df.sort_values(by="Last_Checked", inplace=True)
    generate_plots(df)


if __name__ == "__main__":
    main()
