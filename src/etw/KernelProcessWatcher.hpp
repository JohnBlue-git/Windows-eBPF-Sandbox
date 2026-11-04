#pragma once

#ifndef _WIN32
#error "KernelProcessWatcher is available only on Windows."
#endif

#include <windows.h>
#include <evntrace.h>

#include <cstddef>
#include <functional>
#include <string>
#include <thread>
#include <vector>

// Event header metadata only; the provider payload is not decoded.
struct KernelProcessEvent {
    USHORT event_id;
    UCHAR opcode;
    // The process and thread that logged the event. For ProcessStart (id=1)
    // this is the creating process, not the new one.
    ULONG header_process_id;
    ULONG header_thread_id;
};

class KernelProcessWatcher {
public:
    using EventHandler = std::function<void(KernelProcessEvent)>;

    explicit KernelProcessWatcher(EventHandler on_event);
    KernelProcessWatcher(const KernelProcessWatcher&) = delete;
    KernelProcessWatcher& operator=(const KernelProcessWatcher&) = delete;
    ~KernelProcessWatcher();

    void start();
    void stop();

private:
    static void WINAPI handle_event(PEVENT_RECORD record);
    void process_event(PEVENT_RECORD record) noexcept;
    void consume_events() noexcept;

    EventHandler on_event_;
    std::wstring session_name_;
    TRACEHANDLE session_handle_{0};
    TRACEHANDLE trace_handle_{INVALID_PROCESSTRACE_HANDLE};
    EVENT_TRACE_PROPERTIES* properties_{nullptr};
    std::vector<std::byte> properties_buffer_;
    std::thread worker_;
};