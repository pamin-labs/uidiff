"""Collect native child CPU time and peak working set on Windows."""

import ctypes
import subprocess
import time
from ctypes import wintypes

PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_VM_READ = 0x0010
FILETIME_PER_MS = 10_000


class MemoryCounters(ctypes.Structure):
    _fields_ = [
        ("cb", wintypes.DWORD),
        ("page_fault_count", wintypes.DWORD),
        ("peak_working_set_size", ctypes.c_size_t),
        ("working_set_size", ctypes.c_size_t),
        ("quota_peak_paged_pool_usage", ctypes.c_size_t),
        ("quota_paged_pool_usage", ctypes.c_size_t),
        ("quota_peak_nonpaged_pool_usage", ctypes.c_size_t),
        ("quota_nonpaged_pool_usage", ctypes.c_size_t),
        ("pagefile_usage", ctypes.c_size_t),
        ("peak_pagefile_usage", ctypes.c_size_t),
    ]


kernel = ctypes.WinDLL("kernel32", use_last_error=True)
kernel.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
kernel.OpenProcess.restype = wintypes.HANDLE
kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
kernel.CloseHandle.restype = wintypes.BOOL
kernel.GetProcessTimes.argtypes = (wintypes.HANDLE,) + (ctypes.POINTER(wintypes.FILETIME),) * 4
kernel.GetProcessTimes.restype = wintypes.BOOL
kernel.K32GetProcessMemoryInfo.argtypes = (
    wintypes.HANDLE, ctypes.POINTER(MemoryCounters), wintypes.DWORD,
)
kernel.K32GetProcessMemoryInfo.restype = wintypes.BOOL


def ticks(value):
    return (value.dwHighDateTime << 32) | value.dwLowDateTime


def timed_process(command):
    start = time.perf_counter_ns()
    with subprocess.Popen(command, stdout=subprocess.DEVNULL) as process:
        handle = kernel.OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, False, process.pid)
        if not handle:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            status = process.wait()
            wall_ms = (time.perf_counter_ns() - start) / 1_000_000
            created, exited, system, user = (wintypes.FILETIME() for _ in range(4))
            if not kernel.GetProcessTimes(handle, created, exited, system, user):
                raise ctypes.WinError(ctypes.get_last_error())
            counters = MemoryCounters()
            counters.cb = ctypes.sizeof(counters)
            # A post-exit query can lack a working set. Keep its metric unavailable.
            has_peak = kernel.K32GetProcessMemoryInfo(handle, counters, counters.cb) and counters.peak_working_set_size
            rss_mib = counters.peak_working_set_size / 2**20 if has_peak else None
            return status, wall_ms, (ticks(system) + ticks(user)) / FILETIME_PER_MS, rss_mib
        finally:
            kernel.CloseHandle(handle)
