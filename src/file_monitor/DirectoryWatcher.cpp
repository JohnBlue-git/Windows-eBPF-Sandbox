#include "DirectoryWatcher.hpp"

#include "ActionLoop.hpp"

#include <array>
#include <cstddef>
#include <iostream>
#include <span>
#include <stdexcept>
#include <system_error>
#include <utility>

#include <boost/asio/async_result.hpp>
#include <boost/asio/co_spawn.hpp>
#include <boost/asio/post.hpp>
#include <boost/asio/redirect_error.hpp>
#include <boost/asio/use_awaitable.hpp>
#include <boost/asio/windows/overlapped_ptr.hpp>

namespace asio = boost::asio;

namespace {

// Completed changes to file and directory names, sizes, attributes and write times
// anywhere under the directory.
constexpr DWORD change_filter = FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME |
    FILE_NOTIFY_CHANGE_ATTRIBUTES | FILE_NOTIFY_CHANGE_SIZE |
    FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_CREATION;

[[noreturn]] void throw_windows_error(const char* operation)
{
    throw std::system_error(
        static_cast<int>(GetLastError()), std::system_category(), operation);
}

FileChangeKind to_change_kind(DWORD action)
{
    switch (action) {
    case FILE_ACTION_ADDED: return FileChangeKind::added;
    case FILE_ACTION_REMOVED: return FileChangeKind::removed;
    case FILE_ACTION_MODIFIED: return FileChangeKind::modified;
    case FILE_ACTION_RENAMED_OLD_NAME: return FileChangeKind::renamed_from;
    case FILE_ACTION_RENAMED_NEW_NAME: return FileChangeKind::renamed_to;
    default: return FileChangeKind::unknown;
    }
}

// Starts one overlapped ReadDirectoryChangesW. It completes with the number of
// bytes written to the buffer (0 when the change list overflowed).
template <typename CompletionToken>
auto async_read_changes(
    asio::windows::random_access_handle& directory, std::span<std::byte> buffer, CompletionToken&& token)
{
    return asio::async_initiate<CompletionToken, void(boost::system::error_code, std::size_t)>(
        [&directory, buffer](auto handler) {
            asio::windows::overlapped_ptr overlapped(directory.get_executor(), std::move(handler));
            const BOOL started = ReadDirectoryChangesW(
                directory.native_handle(),
                buffer.data(),
                static_cast<DWORD>(buffer.size()),
                TRUE,
                change_filter,
                nullptr,
                overlapped.get(),
                nullptr);
            const DWORD error = GetLastError();
            if (!started && error != ERROR_IO_PENDING) {
                overlapped.complete(
                    boost::system::error_code(static_cast<int>(error), asio::error::get_system_category()), 0);
            } else {
                overlapped.release();
            }
        },
        token);
}

void report_file_changes(
    const std::byte* buffer, std::size_t bytes_transferred, const DirectoryWatcher::ChangeHandler& on_change)
{
    std::size_t offset = 0;
    while (offset + offsetof(FILE_NOTIFY_INFORMATION, FileName) <= bytes_transferred) {
        const auto* notification = reinterpret_cast<const FILE_NOTIFY_INFORMATION*>(buffer + offset);
        const auto name_bytes = static_cast<std::size_t>(notification->FileNameLength);
        const auto record_size = offsetof(FILE_NOTIFY_INFORMATION, FileName) + name_bytes;

        if (name_bytes % sizeof(wchar_t) != 0 || offset + record_size > bytes_transferred) {
            throw std::runtime_error("ReadDirectoryChangesW returned a malformed notification record");
        }

        try {
            on_change(FileChange{
                std::wstring(notification->FileName, name_bytes / sizeof(wchar_t)),
                to_change_kind(notification->Action),
            });
        } catch (...) {
            report_exception("File-change callback", std::current_exception());
        }

        if (notification->NextEntryOffset == 0) {
            break;
        }
        if (notification->NextEntryOffset < record_size ||
            offset + notification->NextEntryOffset > bytes_transferred) {
            throw std::runtime_error("ReadDirectoryChangesW returned an invalid record offset");
        }
        offset += notification->NextEntryOffset;
    }
}

} // namespace

DirectoryWatcher::DirectoryWatcher(
    asio::any_io_executor executor, std::wstring directory, ChangeHandler on_change)
    : directory_(std::move(directory))
    , on_change_(std::move(on_change))
    , directory_handle_(std::move(executor))
{
    if (directory_.empty() || !on_change_) {
        throw std::invalid_argument("DirectoryWatcher requires a directory and a change handler");
    }
}

DirectoryWatcher::~DirectoryWatcher()
{
    stop();
}

void DirectoryWatcher::start()
{
    if (finished_.valid()) {
        throw std::logic_error("DirectoryWatcher is already running");
    }

    const HANDLE directory = CreateFileW(
        directory_.c_str(),
        FILE_LIST_DIRECTORY,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED,
        nullptr);
    if (directory == INVALID_HANDLE_VALUE) {
        throw_windows_error("CreateFileW");
    }
    // Takes ownership and associates the handle with the IOCP.
    directory_handle_.assign(directory);

    stop_requested_ = false;
    std::promise<void> finished;
    finished_ = finished.get_future();
    asio::co_spawn(
        directory_handle_.get_executor(),
        run(),
        [finished = std::move(finished)](std::exception_ptr error) mutable {
            if (error) {
                report_exception("Directory watch", error);
            }
            finished.set_value();
        });
}

void DirectoryWatcher::stop()
{
    if (!finished_.valid()) {
        return;
    }
    std::promise<void> cancellation_requested;
    auto cancellation_completed = cancellation_requested.get_future();
    asio::post(directory_handle_.get_executor(), [this, cancellation_requested = std::move(cancellation_requested)]() mutable {
        stop_requested_ = true;
        boost::system::error_code ignored;
        directory_handle_.cancel(ignored);
        cancellation_requested.set_value();
    });
    cancellation_completed.get();
    finished_.get();
}

asio::awaitable<void> DirectoryWatcher::run()
{
    alignas(FILE_NOTIFY_INFORMATION) std::array<std::byte, 64 * 1024> buffer{};
    while (!stop_requested_) {
        boost::system::error_code error;
        const std::size_t bytes_transferred = co_await async_read_changes(
            directory_handle_, buffer, asio::redirect_error(asio::use_awaitable, error));
        if (stop_requested_ || error == asio::error::operation_aborted) {
            break;
        }
        if (error) {
            std::cerr << "Reading directory changes failed (Win32 error " << error.value() << ")\n";
            break;
        }
        if (bytes_transferred == 0) {
            std::cerr << "ReadDirectoryChangesW buffer overflowed; rescan the directory for missed changes.\n";
            continue;
        }
        report_file_changes(buffer.data(), bytes_transferred, on_change_);
    }

    boost::system::error_code ignored;
    directory_handle_.close(ignored);
}
