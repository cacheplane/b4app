## 2026-10-31 (M4)

- **D-025 Ownership is `(pid, process start time within one second, argv containing the CLI entry file and the port)` from `KERN_PROC_PID` and `KERN_PROCARGS2`, captured at spawn and re-verified before every signal and on every coordinator start.** A pid or a listening port alone never establishes ownership; a mismatch leaves the process alone and marks the registration stopped with a message naming the pid.
