#pragma once

#ifndef _WIN32
#error "DirectoryWatcher is available only on Windows."
#endif

#include <windows.h>

#include <functional>
#include <future>
#include <string>

#include <boost/asio/any_io_executor.hpp>
#include <boost/asio/awaitable.hpp>
#include <boost/asio/windows/random_access_handle.hpp>

enum class FileChangeKind { added, removed, modified, renamed_from, renamed_to, unknown };

struct FileChange {
    std::wstring relative_path;
    FileChangeKind kind;
};

// Observes completed filesystem changes only. Use a Minifilter to enforce or deny operations.
// ReadDirectoryChangesW runs as overlapped I/O on the executor's Boost.Asio IOCP,
// and the change handler is called on that executor.
class DirectoryWatcher {
public:
    using ChangeHandler = std::function<void(FileChange)>;

    DirectoryWatcher(boost::asio::any_io_executor executor, std::wstring directory, ChangeHandler on_change);
    DirectoryWatcher(const DirectoryWatcher&) = delete;
    DirectoryWatcher& operator=(const DirectoryWatcher&) = delete;
    ~DirectoryWatcher();

    void start();
    // Must not be called from the executor's thread: it waits for the watch to end.
    void stop();

private:
    boost::asio::awaitable<void> run();

    std::wstring directory_;
    ChangeHandler on_change_;
    boost::asio::windows::random_access_handle directory_handle_;
    bool stop_requested_{false};  // used only on the executor
    std::future<void> finished_;
};
