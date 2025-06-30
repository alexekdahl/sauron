import os, strutils, times, posix, math, sequtils

type
  ProcessState = enum
    Running, Sleeping, DiskSleep, Stopped, Zombie, Dead, Unknown

  ProcessDetails = object
    pid: int
    name: string           # From `/proc/<pid>/stat`
    state: ProcessState    # Parsed from stat code
    thread_count: int      # From `/proc/<pid>/status`
    memory_rss: int        # Resident Set Size in kB
    memory_vsz: int        # Virtual Memory Size in kB
    memory_pss: int        # Proportional Set Size in kB
    cpu_usage: float       # Percentage
    uptime: float          # Seconds
    last_checked: string   # ISO timestamp

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
      if trimmed.len == 0 or trimmed.startsWith("#"): continue
      let parts = trimmed.split("=", maxSplit = 1)
      if parts.len == 2:
        let key = parts[0].strip
        let value = parts[1].strip
        case key
        of "check_interval": cfg.check_interval = parseFloat(value)
        of "processes": cfg.processes = value.split(",").mapIt(it.strip)
        of "log_path": cfg.log_path = value
        of "max_log_size": cfg.max_log_size = value.parseInt
        of "max_log_files": cfg.max_log_files = value.parseInt
        else: discard
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
  else: "Unknown"

proc roundTo(num: float, precision: int): float =
  let factor = 10.0^precision.float
  (num * factor).round / factor

proc `$`(pd: ProcessDetails): string =
  "PID: " & $pd.pid &
  " | Name: " & pd.name &
  " | State: " & $pd.state &
  " | Threads: " & $pd.thread_count &
  " | RSS (MB): " & $(roundTo(pd.memory_rss.float / 1000.0, 2)) &
  " | VSZ (MB): " & $(roundTo(pd.memory_vsz.float / 1000.0, 2)) &
  " | PSS (MB): " & $(roundTo(pd.memory_pss.float / 1000.0, 2)) &
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
    if contents.len >= 1: return parseFloat(contents[0])
  return epochTime()

# Safe file read returning empty string on missing process
proc safeRead(path: string): string =
  try:
    return readFile(path)
  except IOError:
    return ""

proc getProcessDetails(pid: int, checkInterval: float): ProcessDetails =
  # Initialize default details for missing processes
  var details = ProcessDetails(
    pid: pid,
    name: "",
    state: Dead,
    thread_count: 0,
    memory_rss: 0,
    memory_vsz: 0,
    memory_pss: 0,
    cpu_usage: 0.0,
    uptime: 0.0,
    last_checked: ""
  )
  let statPath = "/proc/" & $pid & "/stat"
  let statLine = safeRead(statPath)
  if statLine.len == 0:
    return details

  # Parse /proc/<pid>/stat
  let startIdx = statLine.find('(') + 1
  let endIdx = statLine.find(')', startIdx)
  if startIdx <= 0 or endIdx <= startIdx:
    return details
  let procName = statLine[startIdx..<endIdx]
  let rest = statLine[endIdx+2..^1].split(' ')

  # Compute uptime
  let systemUptime = getSystemUptime()
  let startTime = rest[19].parseFloat / ClockTicks
  let processUptime = max(systemUptime - startTime, 0.0)

  # Assign base details
  details.name = procName
  details.state = parseState(rest[0][0])
  details.uptime = roundTo(processUptime, 2)

  # Read /proc/<pid>/status
  let statusPath = "/proc/" & $pid & "/status"
  for line in safeRead(statusPath).splitLines():
    if line.startsWith("Threads:"):
      details.thread_count = line[8..^1].strip.parseInt
    elif line.startsWith("VmRSS:"):
      details.memory_rss = line[6..^1].strip.split()[0].parseInt
    elif line.startsWith("VmSize:"):
      details.memory_vsz = line[7..^1].strip.split()[0].parseInt

  # Read PSS from smaps_rollup or fallback to smaps
  let smapsRoll = "/proc/" & $pid & "/smaps_rollup"
  var pssTotal = 0
  var foundPss = false
  for line in safeRead(smapsRoll).splitLines():
    if line.startsWith("Pss:"):
      pssTotal = line[4..^1].strip.split()[0].parseInt
      foundPss = true
      break
  if not foundPss:
    let smapsFile = "/proc/" & $pid & "/smaps"
    for line in safeRead(smapsFile).splitLines():
      if line.startsWith("Pss:"):
        pssTotal.inc(parseInt(line[4..^1].strip.split()[0]))
  details.memory_pss = pssTotal

  # CPU calculation
  let utime = rest[11].parseFloat
  let stime = rest[12].parseFloat
  let total_time = utime + stime
  if processUptime > 0:
    details.cpu_usage = roundTo((total_time / ClockTicks) / processUptime * 100, 2)

  return details

proc findPIDsByName(targetName: string): seq[int] =
  result = @[]
  for entry in walkDir("/proc"):
    if entry.kind == pcDir:
      let pidStr = extractFilename(entry.path)
      try: discard pidStr.parseInt
      except ValueError: continue
      let pid = pidStr.parseInt
      let statPath = "/proc/" & pidStr & "/stat"
      if fileExists(statPath):
        let line = readFile(statPath)
        let sIdx = line.find('(') + 1
        let eIdx = line.find(')', sIdx)
        if sIdx > 0 and eIdx > sIdx:
          if line[sIdx..<eIdx] == targetName:
            result.add(pid)

# ------------------------------
# Logging System
# ------------------------------

proc rotateLogs(config: AppConfig) =
  if logHandle != nil: close(logHandle)
  let lastLog = config.log_path & $config.max_log_files
  if fileExists(lastLog): removeFile(lastLog)
  for i in countdown(config.max_log_files - 1, 1):
    let oldFile = config.log_path & $i
    if fileExists(oldFile): moveFile(oldFile, config.log_path & $(i+1))
  if fileExists(config.log_path): moveFile(config.log_path, config.log_path & "1")

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
