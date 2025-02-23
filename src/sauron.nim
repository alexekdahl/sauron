import os, strutils, times, posix, math, sequtils

type
  ProcessState = enum
    Running, Sleeping, DiskSleep, Stopped, Zombie, Dead, Unknown

  ProcessDetails = object
    pid: int
    name: string      # Read from `/proc/<pid>/stat`
    state: ProcessState # Parsed from the single-character code in `/proc/<pid>/stat`.
    thread_count: int # Read from `/proc/<pid>/status`.
    memory_rss: int   # Resident Set Size in kB.
    memory_vsz: int   # Virtual Memory Size in kB.
    cpu_usage: float
    uptime: float
    last_checked: string

  AppConfig = object
    check_interval: float
    processes: seq[string]
    log_path: string
    max_log_size: int
    max_log_files: int

const
  ClockTicks = 100.0
  LogPath = "./localdata/process.log"
  ConfigPath = "./localdata/config.cfg"

var
  logHandle: File

# ------------------------------
# Config Utilities
# ------------------------------
proc defaultConfig(): AppConfig =
  result = AppConfig(
    check_interval: 300.0,
    processes: @["sitecontroller_"],
    log_path: LogPath,
    max_log_size: 1_048_576,
    max_log_files: 5
  )

proc writeDefaultConfig(path: string, cfg: AppConfig) =
  var lines: seq[string] = @[]
  lines.add("check_interval = " & $cfg.check_interval)
  lines.add("processes = " & cfg.processes.join(","))
  lines.add("log_path = " & cfg.log_path)
  lines.add("max_log_size = " & $cfg.max_log_size)
  lines.add("max_log_files = " & $cfg.max_log_files)
  writeFile(path, lines.join("\n"))

proc loadConfig(path: string): AppConfig =
  if fileExists(path):
    var cfg = defaultConfig()
    for line in readFile(path).splitLines():
      let trimmed = line.strip()
      if trimmed.len == 0 or trimmed.startsWith("#"):
        continue
      let parts = trimmed.split("=", maxSplit = 1)
      if parts.len == 2:
        let key = parts[0].strip
        let value = parts[1].strip
        case key
        of "check_interval":
          cfg.check_interval = parseFloat(value)
        of "processes":
          cfg.processes = value.split(",").mapIt(it.strip)
        of "log_path":
          cfg.log_path = value
        of "max_log_size":
          cfg.max_log_size = value.parseInt
        of "max_log_files":
          cfg.max_log_files = value.parseInt
        else:
          discard
    return cfg
  else:
    let cfg = defaultConfig()
    writeDefaultConfig(path, cfg)
    return cfg

# ------------------------------
# Logging Helpers
# ------------------------------
proc `$`(ps: ProcessState): string =
  case ps
  of Running: "Running"
  of Sleeping: "Sleeping (interruptible)"
  of DiskSleep: "Sleeping (uninterruptible)"
  of Stopped: "Stopped"
  of Zombie: "Zombie"
  of Dead: "Dead"
  of Unknown: "Unknown"

proc `$`(pd: ProcessDetails): string =
  "PID: " & $pd.pid &
  " | Name: " & pd.name &
  " | State: " & $pd.state &
  " | Threads: " & $pd.thread_count &
  " | RSS (MB): " & $(round(pd.memory_rss.float / 1024, 2)) &
  " | VSZ (MB): " & $(round(pd.memory_vsz.float / 1024, 2)) &
  " | CPU (%): " & $pd.cpu_usage &
  " | Uptime (sec): " & $pd.uptime &
  " | Last Checked: " & pd.last_checked

# ------------------------------
# /proc Parsing Utilities
# ------------------------------
proc parseState(state: char): ProcessState =
  case state
  of 'R': Running
  of 'S': Sleeping
  of 'D': DiskSleep
  of 'T', 't': Stopped
  of 'Z': Zombie
  of 'X': Dead
  else: Unknown

proc getSystemUptime(): float =
  let uptimeFile = "/proc/uptime"
  if fileExists(uptimeFile):
    let contents = readFile(uptimeFile).split()
    if contents.len >= 1:
      return parseFloat(contents[0])
  return epochTime()

proc roundTo(num: float, precision: int): float =
  let factor = 10.0^precision.float
  (num * factor).round / factor

proc getProcessDetails(pid: int, checkInterval: float): ProcessDetails =
  let statPath = "/proc/" & $pid & "/stat"
  if not fileExists(statPath):
    return ProcessDetails(pid: pid, name: "", state: Dead,
      thread_count: 0, memory_rss: 0, memory_vsz: 0,
      cpu_usage: 0.0, uptime: 0.0, last_checked: "")
  let statLine = readFile(statPath)
  let startIdx = statLine.find('(') + 1
  let endIdx = statLine.find(')', startIdx)
  let procName = statLine[startIdx..<endIdx]
  let rest = statLine[endIdx+2..^1].split(' ')
  let systemUptime = getSystemUptime()
  let startTime = rest[19].parseFloat / ClockTicks
  let processUptime = max(systemUptime - startTime, 0.0)
  var details = ProcessDetails(
    pid: pid,
    name: procName,
    state: parseState(rest[0][0]),
    thread_count: 0,
    memory_rss: 0,
    memory_vsz: 0,
    cpu_usage: 0.0,
    uptime: roundTo(processUptime, 2),
    last_checked: ""
  )
  let statusPath = "/proc/" & $pid & "/status"
  if fileExists(statusPath):
    for line in lines(statusPath):
      if line.startsWith("Threads:"):
        details.thread_count = line[8..^1].strip.parseInt
      elif line.startsWith("VmRSS:"):
        let rssStr = line[6..^1].strip.split()[0]
        details.memory_rss = rssStr.parseInt
      elif line.startsWith("VmSize:"):
        let vszStr = line[7..^1].strip.split()[0]
        details.memory_vsz = vszStr.parseInt

  let utime = rest[11].parseFloat
  let stime = rest[12].parseFloat
  let total_time = utime + stime

  if processUptime > 0:
    details.cpu_usage = roundTo((total_time / ClockTicks) / processUptime * 100, 2)
  else:
    details.cpu_usage = 0.0

  return details

proc findPIDsByName(targetName: string): seq[int] =
  var pids: seq[int] = @[]
  for entry in walkDir("/proc"):
    if entry.kind == pcDir:
      let pidStr = extractFilename(entry.path)
      try:
        discard pidStr.parseInt
      except ValueError:
        continue

      let pid = pidStr.parseInt
      let statPath = "/proc/" & pidStr & "/stat"
      if fileExists(statPath):
        let statLine = readFile(statPath)
        let startIdx = statLine.find('(') + 1
        let endIdx = statLine.find(')', startIdx)
        if startIdx > 0 and endIdx > startIdx:
          let procName = statLine[startIdx..<endIdx]
          if procName == targetName:
            pids.add(pid)
  return pids

# ------------------------------
# Logging System
# ------------------------------
proc rotateLogs(config: AppConfig) =
  if logHandle != nil:
    close(logHandle)
  let lastLog = config.log_path & $config.max_log_files
  if fileExists(lastLog):
    removeFile(lastLog)
  for i in countdown(config.max_log_files - 1, 1):
    let oldFile = config.log_path & $i
    let newFile = config.log_path & $(i+1)
    if fileExists(oldFile):
      moveFile(oldFile, newFile)
  if fileExists(config.log_path):
    moveFile(config.log_path, config.log_path & "1")

proc initLogging(config: AppConfig) =
  createDir(config.log_path.splitPath.head)
  logHandle = open(config.log_path, fmAppend)


proc writeProcDetails(config: AppConfig) =
  let timestamp = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fffzzz")
  for procName in config.processes:
    for pid in findPIDsByName(procName):
      var details = getProcessDetails(pid, config.check_interval)
      details.last_checked = timestamp
      writeLine(logHandle, $details)
  flushFile(logHandle)
  if getFileSize(config.log_path) > config.max_log_size:
    rotateLogs(config)
    logHandle = open(config.log_path, fmAppend)

# ------------------------------
# Main Application
# ------------------------------
when isMainModule:
  var config = loadConfig(ConfigPath)
  initLogging(config)
  while true:
    let startTime = epochTime()
    writeProcDetails(config)
    let elapsed = epochTime() - startTime
    let sleepTime = max(config.check_interval - elapsed, 0.0) * 1000
    sleep sleepTime.int
