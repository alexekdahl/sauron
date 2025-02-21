package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"
)

type ProcessStats struct {
	TotalCPU      float64
	TotalMemory   float64
	MinMemory     float64
	MaxMemory     float64
	MinCPU        float64
	MaxCPU        float64
	Count         int
	MaxMemoryTime string
	MaxCPUTime    string
}

type LogEntry struct {
	Name      string
	CPU       float64
	Memory    float64
	Timestamp time.Time
}

// parseLogEntry parses a single log line into a LogEntry struct.
func parseLogEntry(line string) (*LogEntry, error) {
	parts := strings.Split(line, " | ")
	if len(parts) < 9 {
		return nil, fmt.Errorf("insufficient log parts")
	}

	nameParts := strings.Split(parts[1], ": ")
	if len(nameParts) != 2 {
		return nil, fmt.Errorf("invalid process name format")
	}
	name := nameParts[1]

	cpuParts := strings.Split(parts[6], ": ")
	if len(cpuParts) != 2 {
		return nil, fmt.Errorf("invalid CPU usage format")
	}
	cpu, err := strconv.ParseFloat(cpuParts[1], 64)
	if err != nil {
		return nil, fmt.Errorf("invalid CPU value: %v", err)
	}

	// Extract memory usage from "RSS (MB): ..." (parts[4])
	memParts := strings.Split(parts[4], ": ")
	if len(memParts) != 2 {
		return nil, fmt.Errorf("invalid memory usage format")
	}
	memory, err := strconv.ParseFloat(memParts[1], 64)
	if err != nil {
		return nil, fmt.Errorf("invalid memory value: %v", err)
	}

	tsStr := strings.TrimPrefix(parts[8], "Last Checked: ")
	timestamp, err := time.Parse(time.RFC3339Nano, tsStr)
	if err != nil {
		return nil, fmt.Errorf("invalid timestamp: %v", err)
	}

	return &LogEntry{
		Name:      name,
		CPU:       cpu,
		Memory:    memory,
		Timestamp: timestamp,
	}, nil
}

// updateStats updates the ProcessStats map with the new LogEntry.
func updateStats(stats map[string]ProcessStats, entry *LogEntry) {
	tsStr := entry.Timestamp.Format("2006-01-02 15:04:05")
	stat, exists := stats[entry.Name]
	if !exists {
		stat = ProcessStats{
			MinMemory: entry.Memory,
			MaxMemory: entry.Memory,
			MinCPU:    entry.CPU,
			MaxCPU:    entry.CPU,
		}
	}

	stat.TotalCPU += entry.CPU
	stat.TotalMemory += entry.Memory
	stat.MinMemory = min(stat.MinMemory, entry.Memory)
	stat.MaxMemory = max(stat.MaxMemory, entry.Memory)
	stat.MinCPU = min(stat.MinCPU, entry.CPU)
	stat.MaxCPU = max(stat.MaxCPU, entry.CPU)

	if stat.MaxMemory == entry.Memory {
		stat.MaxMemoryTime = tsStr
	}
	if stat.MaxCPU == entry.CPU {
		stat.MaxCPUTime = tsStr
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
			// Skip malformed lines; optionally log the error.
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
	for name, stat := range stats {
		avgCPU := stat.TotalCPU / float64(stat.Count)
		avgMemory := stat.TotalMemory / float64(stat.Count)

		fmt.Printf("Process %s:\n", name)
		fmt.Printf("  Avg CPU Usage: %.2f%%\n", avgCPU)
		fmt.Printf("  Min CPU Usage: %.2f%%\n", stat.MinCPU)
		fmt.Printf("  Max CPU Usage: %.2f%% (At: %s)\n", stat.MaxCPU, stat.MaxCPUTime)
		fmt.Printf("  Avg Memory Usage: %.2f MB\n", avgMemory)
		fmt.Printf("  Min Memory Usage: %.2f MB\n", stat.MinMemory)
		fmt.Printf("  Max Memory Usage: %.2f MB (At: %s)\n\n", stat.MaxMemory, stat.MaxMemoryTime)
	}
}

func min(a, b float64) float64 {
	if a < b {
		return a
	}
	return b
}

func max(a, b float64) float64 {
	if a > b {
		return a
	}
	return b
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
		defer file.Close()
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
