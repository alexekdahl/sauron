import std/[os, strutils, times, json, posix, net, nativesockets, math, locks, tables, sequtils]

type
  ProcessState = enum
    Running, Sleeping, DiskSleep, Stopped, Zombie, Dead, Unknown

  ProcessDetails = object
    pid: int
    name: string
    state: ProcessState
    parent_pid: int
    thread_count: int
    memory_rss: int 
    memory_vsz: int 
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

var
  serverSocket: Socket
  logHandle: File
  procDetails = initTable[int, ProcessDetails]()
  configLock: Lock

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
    "\"parent_pid\": " & $pd.parent_pid & ", " &
    "\"thread_count\": " & $pd.thread_count & ", " &
    "\"memory_rss_mb\": " & $(round(pd.memory_rss.float / 1024, 2)) & ", " &
    "\"memory_vsz_mb\": " & $(round(pd.memory_vsz.float / 1024, 2)) & ", " &
    "\"cpu_usage_percent\": " & $pd.cpu_usage & ", " &
    "\"uptime_sec\": " & $pd.uptime & ", " &
    "\"last_checked\": \"" & pd.last_checked & "\"" &
  "}"

proc `$`(t: Table[int, ProcessDetails]): string =
  var items: seq[string] = @[]
  for _, v in t.pairs:
    items.add($v)
  "[" & items.join(", ") & "]"

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
    return ProcessDetails(pid: pid, name: "", state: Dead, parent_pid: 0,
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
    parent_pid: rest[1].parseInt,
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
  if fileExists(config.log_path) and getFileSize(config.log_path) > 0:
    rotateLogs(config)
  logHandle = open(config.log_path, fmAppend)

proc writeProcDetails(config: AppConfig) =
  let timestamp = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fffzzz")
  withLock configLock:
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
# HTTP Server
# ------------------------------
proc initServer() =
  serverSocket = newSocket()
  serverSocket.setSockOpt(OptReuseAddr, true)
  serverSocket.bindAddr(Port(43069))
  serverSocket.listen()
  serverSocket.getFd.setBlocking(false)

proc handleRequests(config: AppConfig) =
  var readFds: TFdSet
  FD_ZERO(readFds)
  FD_SET(serverSocket.getFd.cint, readFds)
  var timeout = Timeval(tv_sec: posix.Time(0), tv_usec: 100_000)
  let res = select(serverSocket.getFd.cint + 1, addr readFds, nil, nil, addr timeout)
  if res > 0:
    try:
      var client: Socket
      serverSocket.accept(client)
      let headers = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
      withLock configLock:
        let response = headers & $procDetails
        client.send(response, flags = {SocketFlag.SafeDisconn})
      client.close()
    except:
      discard

# ------------------------------
# Main Application
# ------------------------------
proc main() =
  var config: AppConfig
  let configSource = readFile("./localdata/config.json")
  let j = parseJson(configSource)
  config = AppConfig(
    check_interval: j["check_interval"].getFloat,
    processes: j["processes"].getElems.mapIt(it.getStr),
    log_path: j["log_path"].getStr("/var/log/watchdog.log"),
    max_log_size: j["max_log_size"].getInt(1_048_576),
    max_log_files: j["max_log_files"].getInt(5)
  )
  initLock(configLock)
  initLogging(config)
  initServer()
  while true:
    let startTime = epochTime()
    # Update process details for all matching PIDs from process names.
    writeProcDetails(config)
    handleRequests(config)
    let elapsed = epochTime() - startTime
    let sleepTime = max(config.check_interval - elapsed, 0.0) * 1000
    sleep(sleepTime.int)

when isMainModule:
  main()
  deinitLock(configLock)
  if logHandle != nil: close(logHandle)

