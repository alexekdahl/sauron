import os, strutils, times, posix, math

# ==============================================================================
# Minimal types and constants
# ==============================================================================

const
  ClockTicks = 100.0
  LogPath = "./localdata/process.log"
  ConfigPath = "./localdata/config.cfg"
  BufferSize = 512

var
  logHandle: File
  buffer: array[BufferSize, char] # Stack-allocated buffer

# ==============================================================================
# Minimal utilities - no allocations
# ==============================================================================

proc parseState(c: char): string =
  case c
  of 'R': "Running"
  of 'S': "Sleeping (interruptible)"
  of 'D': "Sleeping (uninterruptible)"
  of 'T', 't': "Stopped"
  of 'Z': "Zombie"
  of 'X': "Dead"
  else: "Unknown"

proc writeFloat(f: File, val: float, precision: int) =
  ## Write float with precision without allocation
  let factor = pow(10.0, precision.float)
  let rounded = round(val * factor) / factor
  f.write($rounded)

proc parseIntFromBuffer(buf: openarray[char], start, stop: int): int =
  ## Parse int from buffer slice without creating string
  result = 0
  var i = start
  while i < stop and buf[i] in {' ', '\t'}: inc i # Skip whitespace
  while i < stop and buf[i] in '0'..'9':
    result = result * 10 + (ord(buf[i]) - ord('0'))
    inc i

proc parseFloatFromBuffer(buf: openarray[char], start, stop: int): float =
  ## Simple float parser from buffer
  result = 0.0
  var i = start
  var decimal = false
  var decimalPlace = 0.1

  while i < stop and buf[i] in {' ', '\t'}: inc i
  while i < stop:
    if buf[i] in '0'..'9':
      if decimal:
        result += float(ord(buf[i]) - ord('0')) * decimalPlace
        decimalPlace *= 0.1
      else:
        result = result * 10.0 + float(ord(buf[i]) - ord('0'))
    elif buf[i] == '.':
      decimal = true
    else:
      break
    inc i

# ==============================================================================
# Direct streaming process logger
# ==============================================================================

proc logProcess(pid: int, name: string, checkInterval: float) =
  ## Stream process info directly to log with minimal memory
  let pidStr = $pid

  # Start log line
  logHandle.write("PID: ")
  logHandle.write(pidStr)
  logHandle.write(" | Name: ")
  logHandle.write(name)

  var
    state = 'X'
    threads = 0
    rss = 0
    vsz = 0
    pss = 0
    utime = 0.0
    stime = 0.0
    starttime = 0.0

  # Read stat file
  var statFile: File
  if open(statFile, "/proc/" & pidStr & "/stat", fmRead):
    var bytesRead = statFile.readChars(buffer, 0, BufferSize-1)
    if bytesRead > 0:
      buffer[bytesRead] = '\0'

      # Find end of command name
      var i = 0
      while i < bytesRead and buffer[i] != '(': inc i
      while i < bytesRead and buffer[i] != ')': inc i
      if i < bytesRead - 2:
        inc i, 2 # Skip ") "
        state = buffer[i]

        # Parse fields - count spaces
        var fieldStart = i + 2
        var fieldNum = 0
        for j in fieldStart..<bytesRead:
          if buffer[j] == ' ':
            case fieldNum
            of 11: utime = parseFloatFromBuffer(buffer, fieldStart, j)
            of 12: stime = parseFloatFromBuffer(buffer, fieldStart, j)
            of 19: starttime = parseFloatFromBuffer(buffer, fieldStart, j)
            else: discard

            fieldStart = j + 1
            inc fieldNum
            if fieldNum > 19: break
    statFile.close()

  logHandle.write(" | State: ")
  logHandle.write(parseState(state))

  # Read status file for memory/threads
  var statusFile: File
  if open(statusFile, "/proc/" & pidStr & "/status", fmRead):
    var line: string
    while statusFile.readLine(line):
      if line.startsWith("Threads:"):
        threads = parseInt(line[8..^1].strip())
      elif line.startsWith("VmRSS:"):
        let parts = line[6..^1].strip().split()
        if parts.len > 0: rss = parseInt(parts[0])
      elif line.startsWith("VmSize:"):
        let parts = line[7..^1].strip().split()
        if parts.len > 0: vsz = parseInt(parts[0])
    statusFile.close()

  # Read PSS from smaps_rollup
  var smapsFile: File
  if open(smapsFile, "/proc/" & pidStr & "/smaps_rollup", fmRead):
    var line: string
    while smapsFile.readLine(line):
      if line.startsWith("Pss:"):
        let parts = line[4..^1].strip().split()
        if parts.len > 0:
          pss = parseInt(parts[0])
          break
    smapsFile.close()

  # Write rest of log line
  logHandle.write(" | Threads: ")
  logHandle.write($threads)
  logHandle.write(" | RSS (MB): ")
  writeFloat(logHandle, rss.float / 1000.0, 2)
  logHandle.write(" | VSZ (MB): ")
  writeFloat(logHandle, vsz.float / 1000.0, 2)
  logHandle.write(" | PSS (MB): ")
  writeFloat(logHandle, pss.float / 1000.0, 2)

  # Calculate CPU and uptime
  logHandle.write(" | CPU (%): ")
  var uptimeFile: File
  if open(uptimeFile, "/proc/uptime", fmRead):
    var line: string
    if uptimeFile.readLine(line):
      let systemUptime = parseFloat(line.split()[0])
      let processUptime = max(systemUptime - starttime / ClockTicks, 0.0)
      let cpuPercent = if processUptime > 0: (utime + stime) / ClockTicks /
          processUptime * 100.0 else: 0.0

      writeFloat(logHandle, cpuPercent, 2)
      logHandle.write(" | Uptime (sec): ")
      writeFloat(logHandle, processUptime, 2)
    uptimeFile.close()
  else:
    logHandle.write("0.0 | Uptime (sec): 0.0")

  logHandle.write(" | Last Checked: ")
  logHandle.write(now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fffzzz"))
  logHandle.write("\n")

# ==============================================================================
# Main loop - streaming approach
# ==============================================================================

proc processMonitor(procName: string, checkInterval: float) =
  ## Find and log process by name
  var found = false

  for entry in walkDir("/proc"):
    if entry.kind != pcDir: continue

    let pidStr = entry.path.extractFilename()

    # Quick numeric check
    var isNum = true
    for c in pidStr:
      if c notin '0'..'9':
        isNum = false
        break
    if not isNum: continue

    # Read just enough of stat to get process name
    var statFile: File
    if open(statFile, "/proc/" & pidStr & "/stat", fmRead):
      var bytesRead = statFile.readChars(buffer, 0, BufferSize-1)
      if bytesRead > 0:
        buffer[bytesRead] = '\0'

        # Extract name between parentheses
        var nameStart = -1
        var nameEnd = -1
        for i in 0..<bytesRead:
          if buffer[i] == '(' and nameStart < 0:
            nameStart = i + 1
          elif buffer[i] == ')':
            nameEnd = i

        if nameStart >= 0 and nameEnd > nameStart:
          # Compare name in-place
          var matches = true
          if nameEnd - nameStart == procName.len:
            for i in 0..<procName.len:
              if buffer[nameStart + i] != procName[i]:
                matches = false
                break
          else:
            matches = false

          if matches:
            found = true
            statFile.close()
            logProcess(parseInt(pidStr), procName, checkInterval)
            continue
      statFile.close()

  if not found:
    logHandle.write("Process not found: ")
    logHandle.write(procName)
    logHandle.write(" | Last Checked: ")
    logHandle.write(now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fffzzz"))
    logHandle.write("\n")

# ==============================================================================
# Config and main
# ==============================================================================

type Config = tuple[interval: float, processes: seq[string], logPath: string,
    maxSize: int, maxFiles: int]

proc loadConfig(): Config =
  result.interval = 300.0
  result.processes = @["sitecontroller_"]
  result.logPath = LogPath
  result.maxSize = 1_048_576
  result.maxFiles = 5

  if fileExists(ConfigPath):
    for line in lines(ConfigPath):
      let trimmed = line.strip()
      if trimmed.len > 0 and trimmed[0] != '#':
        let parts = trimmed.split('=', 1)
        if parts.len == 2:
          let key = parts[0].strip()
          let val = parts[1].strip()
          case key
          of "check_interval": result.interval = parseFloat(val)
          of "processes": result.processes = val.split(',').mapIt(it.strip())
          of "log_path": result.logPath = val
          of "max_log_size": result.maxSize = parseInt(val)
          of "max_log_files": result.maxFiles = parseInt(val)

proc rotateIfNeeded(config: Config) =
  try:
    if getFileSize(config.logPath) > config.maxSize:
      logHandle.close()

      # Simple rotation
      if fileExists(config.logPath & $config.maxFiles):
        removeFile(config.logPath & $config.maxFiles)

      for i in countdown(config.maxFiles - 1, 1):
        let old = config.logPath & $i
        if fileExists(old):
          moveFile(old, config.logPath & $(i + 1))

      if fileExists(config.logPath):
        moveFile(config.logPath, config.logPath & "1")

      logHandle = open(config.logPath, fmAppend)
  except:
    discard

when isMainModule:
  let config = loadConfig()
  createDir(splitPath(config.logPath).head)
  logHandle = open(config.logPath, fmAppend)

  while true:
    let start = epochTime()

    for procName in config.processes:
      processMonitor(procName, config.interval)

    flushFile(logHandle)
    rotateIfNeeded(config)

    let elapsed = epochTime() - start
    let sleepMs = int(max(config.interval - elapsed, 0.0) * 1000)
    sleep(sleepMs)
