package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"
)

type ProcessStats struct {
	TotalCPU      float64
	TotalMemory   float64
	TotalPSS      float64
	MinMemory     float64
	MaxMemory     float64
	MinPSS        float64
	MaxPSS        float64
	MinCPU        float64
	MaxCPU        float64
	Count         int
	MaxMemoryTime string
	MaxPSSTime    string
	MaxCPUTime    string
	LatestCPU     float64
	LatestMemory  float64
	LatestPSS     float64
	LatestTime    time.Time
	State         string
}

type LogEntry struct {
	Name      string
	State     string
	CPU       float64
	Memory    float64 // RSS in MB
	PSS       float64 // PSS in MB
	Timestamp time.Time
}

// parseLogEntry parses a single log line into a LogEntry struct.
func parseLogEntry(line string) (*LogEntry, error) {
	parts := strings.Split(line, " | ")
	if len(parts) < 10 {
		return nil, fmt.Errorf("insufficient log parts: %d", len(parts))
	}

	// parts indices:
	// 0: PID: ...
	// 1: Name: ...
	// 2: State: ...
	// 3: Threads: ...
	// 4: RSS (MB): ...
	// 5: VSZ (MB): ...
	// 6: PSS (MB): ...
	// 7: CPU (%): ...
	// 8: Uptime (sec): ...
	// 9: Last Checked: ...

	// Name
	nameParts := strings.Split(parts[1], ": ")
	if len(nameParts) != 2 {
		return nil, fmt.Errorf("invalid process name format")
	}
	name := nameParts[1]

	// State
	stateParts := strings.Split(parts[2], ": ")
	if len(stateParts) != 2 {
		return nil, fmt.Errorf("invalid process state format")
	}
	state := stateParts[1]

	// Memory (RSS)
	memParts := strings.Split(parts[4], ": ")
	if len(memParts) != 2 {
		return nil, fmt.Errorf("invalid RSS format")
	}
	memory, err := strconv.ParseFloat(strings.TrimSpace(memParts[1]), 64)
	if err != nil {
		return nil, fmt.Errorf("invalid RSS value: %v", err)
	}

	// PSS
	pssParts := strings.Split(parts[6], ": ")
	if len(pssParts) != 2 {
		return nil, fmt.Errorf("invalid PSS format")
	}
	pss, err := strconv.ParseFloat(strings.TrimSpace(pssParts[1]), 64)
	if err != nil {
		return nil, fmt.Errorf("invalid PSS value: %v", err)
	}

	// CPU
	cpuParts := strings.Split(parts[7], ": ")
	if len(cpuParts) != 2 {
		return nil, fmt.Errorf("invalid CPU usage format")
	}
	cpu, err := strconv.ParseFloat(strings.TrimSuffix(strings.TrimSpace(cpuParts[1]), "%"), 64)
	if err != nil {
		return nil, fmt.Errorf("invalid CPU value: %v", err)
	}

	// Timestamp
	tsStr := strings.TrimPrefix(parts[9], "Last Checked: ")
	timestamp, err := time.Parse(time.RFC3339Nano, tsStr)
	if err != nil {
		return nil, fmt.Errorf("invalid timestamp: %v", err)
	}

	return &LogEntry{
		Name:      name,
		State:     state,
		CPU:       cpu,
		Memory:    memory,
		PSS:       pss,
		Timestamp: timestamp,
	}, nil
}

// updateStats updates the ProcessStats map with the new LogEntry.
func updateStats(stats map[string]ProcessStats, entry *LogEntry) {
	tsStr := entry.Timestamp.Format("2006-01-02 15:04:05")
	stat, exists := stats[entry.Name]
	if !exists {
		stat = ProcessStats{
			State:        entry.State,
			MinMemory:    entry.Memory,
			MaxMemory:    entry.Memory,
			MinPSS:       entry.PSS,
			MaxPSS:       entry.PSS,
			MinCPU:       entry.CPU,
			MaxCPU:       entry.CPU,
			LatestCPU:    entry.CPU,
			LatestMemory: entry.Memory,
			LatestPSS:    entry.PSS,
			LatestTime:   entry.Timestamp,
		}
	}

	// Aggregate
	stat.TotalCPU += entry.CPU
	stat.TotalMemory += entry.Memory
	stat.TotalPSS += entry.PSS

	// Min/Max
	if entry.Memory < stat.MinMemory {
		stat.MinMemory = entry.Memory
	}
	if entry.Memory > stat.MaxMemory {
		stat.MaxMemory = entry.Memory
		stat.MaxMemoryTime = tsStr
	}
	if entry.PSS < stat.MinPSS {
		stat.MinPSS = entry.PSS
	}
	if entry.PSS > stat.MaxPSS {
		stat.MaxPSS = entry.PSS
		stat.MaxPSSTime = tsStr
	}
	if entry.CPU < stat.MinCPU {
		stat.MinCPU = entry.CPU
	}
	if entry.CPU > stat.MaxCPU {
		stat.MaxCPU = entry.CPU
		stat.MaxCPUTime = tsStr
	}

	// Latest
	if entry.Timestamp.After(stat.LatestTime) {
		stat.LatestCPU = entry.CPU
		stat.LatestMemory = entry.Memory
		stat.LatestPSS = entry.PSS
		stat.LatestTime = entry.Timestamp
	}

	stat.Count++
	stats[entry.Name] = stat
}

// processLogs reads log data from an io.Reader and processes each line.
func processLogs(r io.Reader) (map[string]ProcessStats, error) {
	stats := make(map[string]ProcessStats)
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		line := scanner.Text()
		entry, err := parseLogEntry(line)
		if err != nil {
			continue
		}
		updateStats(stats, entry)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return stats, nil
}

// printStats outputs the process statistics in a formatted way.
func printStats(stats map[string]ProcessStats) {
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	for name, stat := range stats {
		avgCPU := stat.TotalCPU / float64(stat.Count)
		avgMem := stat.TotalMemory / float64(stat.Count)
		avgPSS := stat.TotalPSS / float64(stat.Count)
		latestTimeStr := stat.LatestTime.Format("2006-01-02 15:04:05")

		_, _ = fmt.Fprintf(w, "Process %s:\n", name)
		_, _ = fmt.Fprintf(w, "  %-22s\t%s\n", "State:", stat.State)
		_, _ = fmt.Fprintf(w, "  %-22s\t%.2f%%\n", "Avg CPU Usage:", avgCPU)
		_, _ = fmt.Fprintf(w, "  %-22s\t%.2f%%\n", "Min CPU Usage:", stat.MinCPU)
		_, _ = fmt.Fprintf(w, "  %-22s\t%.2f%% (At: %s)\n", "Max CPU Usage:", stat.MaxCPU, stat.MaxCPUTime)
		_, _ = fmt.Fprintf(w, "  %-22s\t%.2f%% (Latest: %s)\n", "Latest CPU Usage:", stat.LatestCPU, latestTimeStr)
		_, _ = fmt.Fprintf(w, "  %-22s\t%.2f MB\n", "Avg RSS (MB):", avgMem)
		_, _ = fmt.Fprintf(w, "  %-22s\t%.2f MB\n", "Min RSS (MB):", stat.MinMemory)
		_, _ = fmt.Fprintf(w, "  %-22s\t%.2f MB (At: %s)\n", "Max RSS (MB):", stat.MaxMemory, stat.MaxMemoryTime)
		_, _ = fmt.Fprintf(w, "  %-22s\t%.2f MB (Latest: %s)\n", "Latest RSS (MB):", stat.LatestMemory, latestTimeStr)
		_, _ = fmt.Fprintf(w, "  %-22s\t%.2f MB\n", "Avg PSS (MB):", avgPSS)
		_, _ = fmt.Fprintf(w, "  %-22s\t%.2f MB\n", "Min PSS (MB):", stat.MinPSS)
		_, _ = fmt.Fprintf(w, "  %-22s\t%.2f MB (At: %s)\n", "Max PSS (MB):", stat.MaxPSS, stat.MaxPSSTime)
		_, _ = fmt.Fprintf(w, "  %-22s\t%.2f MB (Latest: %s)\n", "Latest PSS (MB):", stat.LatestPSS, latestTimeStr)
		_, _ = fmt.Fprintln(w)
	}
	_ = w.Flush()
}

func main() {
	var reader io.Reader

	// If a file path is provided as an argument, use it.
	if len(os.Args) > 1 {
		file, err := os.Open(os.Args[1])
		if err != nil {
			fmt.Println("Error opening file:", err)
			return
		}
		defer file.Close() //nolint:errcheck
		reader = file
	} else {
		// Otherwise, check if there is piped input.
		stat, err := os.Stdin.Stat()
		if err != nil {
			fmt.Println("Error reading stdin:", err)
			return
		}
		if (stat.Mode() & os.ModeCharDevice) != 0 {
			fmt.Println("Usage: <log_file_path> or pipe log data to stdin")
			return
		}
		reader = os.Stdin
	}

	stats, err := processLogs(reader)
	if err != nil {
		fmt.Println("Error processing logs:", err)
		return
	}

	printStats(stats)
}
