# Sauron - The All-Seeing Process Monitor

![License](https://img.shields.io/badge/license-MIT-green)
![Contributions Welcome](https://img.shields.io/badge/contributions-welcome-brightgreen)

Welcome to Sauron—the all-seeing process monitor acap for Axis cameras. With Sauron, you get a lightweight tool that keeps a watchful eye on your camera's processes, ensuring everything is running smoothly.

### What Is Sauron?
Sauron is a minimalistic process monitor written in Nim. It reads system data directly from /proc on your Axis camera, logging essential details like CPU usage, memory stats, and uptime in a simple, human-readable format. I’ve stripped away bulky dependencies so that Sauron stays lean and fast.

### Features
* Lightweight & Minimal.
* Process Monitoring: Keeps track of specific processes by name.
* Simple Config & Logs: Uses an easy key–value config file and plain text logs.
* Multi-Architecture Support: Build for aarch64, armv7, amd64, and mipsle.
* Docker-Ready: Consistent builds via Docker are supported.
* ACAP-Ready: Built to run on Axis cameras as an acap.

### Configuration
Sauron uses a straightforward key–value config file located at localdata/config.cfg. A sample config might look like this:

```ini
check_interval = 300.0
processes = mdnsd,httpd
log_path = ./localdata/process.log
max_log_size = 1048576
max_log_files = 5
```

## Final Words
Sauron stands vigilant over your Axis camera—just like its namesake, the Dark Lord with his all-seeing eye. Whether you're ensuring your critical processes are running or just keeping a digital watch, Sauron has you covered.

Happy monitoring!
