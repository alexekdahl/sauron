import std/[os, strutils, times, json, posix, math, tables, sequtils]

type
  ProcessState = enum
    Running, Sleeping, DiskSleep, Stopped, Zombie, Dead, Unknown

type
  ProcessDetails = object
    pid: int
    name: string      # Read from `/proc/<pid>/stat`
    state: ProcessState # Parsed from the single-character code in `/proc/<pid>/stat`.
    thread_count: int #  Read from `/proc/<pid>/status`.
    memory_rss: int   # Obtained from `VmRSS:` in `/proc/<pid>/status`
      ## The Resident Set Size in kilobytes (kB). This is the non-swapped physical
      ## memory the process has in RAM.
    memory_vsz: int # Obtained from `VmSize:` in `/proc/<pid>/status`.
      ## The Virtual Memory Size in kilobytes (kB). This is the total virtual
      ## memory allocated to the process, including all mapped files and libraries.
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
  ClockTicks = 100.0 # Default for most Linux systems
  LogPath = "./localdata/data.json"
  ConfigPath = "./localdata/config.json"

var
  logHandle: File
  procDetails = initTable[int, ProcessDetails]()

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

proc loadConfig(path: string): AppConfig =
  if fileExists(path):
    let configSource = readFile(path)
    try:
      let cfg = parseJson(configSource)
      return AppConfig(
        check_interval: cfg["check_interval"].getFloat(default = 300.0),
        processes: cfg["processes"].getElems().mapIt(it.getStr(
            default = "sitecontroller_")),
        log_path: cfg["log_path"].getStr(default = "./localdata/data.json"),
        max_log_size: cfg["max_log_size"].getInt(default = 1_048_576),
        max_log_files: cfg["max_log_files"].getInt(default = 5)
      )

    except:
      raise newException(ValueError, "Invalid configuration file.")

  let default = defaultConfig()
  writeFile(path, pretty(%default))
  return default

# ------------------------------
# JSON Conversion Helpers
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
  "{" &
    "\"pid\": " & $pd.pid & ", " &
    "\"name\": \"" & pd.name & "\", " &
    "\"state\": \"" & $pd.state & "\", " &
    "\"thread_count\": " & $pd.thread_count & ", " &
    "\"memory_rss_mb\": " & $(round(pd.memory_rss.float / 1024, 2)) & ", " &
    "\"memory_vsz_mb\": " & $(round(pd.memory_vsz.float / 1024, 2)) & ", " &
    "\"cpu_usage_percent\": " & $pd.cpu_usage & ", " &
    "\"uptime_sec\": " & $pd.uptime & ", " &
    "\"last_checked\": \"" & pd.last_checked & "\"" &
  "}"

# ------------------------------
# /proc Parsing Utilities
# ------------------------------
proc parseState(state: char): ProcessState =
  case state:
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
  return epochTime() # Fallback to system time

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
    # For each process name, find matching PIDs and update their details.
  for procName in config.processes:
    for pid in findPIDsByName(procName):
      var details = getProcessDetails(pid, config.check_interval)
      details.last_checked = timestamp
      procDetails[pid] = details
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
    # Update process details for all matching PIDs from process names.
    writeProcDetails(config)
    let elapsed = epochTime() - startTime
    let sleepTime = max(config.check_interval - elapsed, 0.0) * 1000
    sleep sleepTime.int
