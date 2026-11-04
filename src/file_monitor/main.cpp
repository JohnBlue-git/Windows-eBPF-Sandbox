#include "ActionLoop.hpp"
#include "DirectoryWatcher.hpp"

#include <iostream>
#include <memory>
#include <string>

namespace {

const wchar_t* kind_name(FileChangeKind kind)
{
    switch (kind) {
    case FileChangeKind::added: return L"added";
    case FileChangeKind::removed: return L"removed";
    case FileChangeKind::modified: return L"modified";
    case FileChangeKind::renamed_from: return L"rename-from";
    case FileChangeKind::renamed_to: return L"rename-to";
    case FileChangeKind::unknown: break;
    }
    return L"unknown";
}

class FileChangeLogAction final : public IAction {
public:
    explicit FileChangeLogAction(FileChange change)
        : change_(std::move(change))
    {
    }

    boost::asio::awaitable<void> execute_async() override
    {
        std::wcout << kind_name(change_.kind) << L": " << change_.relative_path << L'\n';
        co_return;
    }

private:
    FileChange change_;
};

} // namespace

int wmain(int argc, wchar_t* argv[])
{
    if (argc != 2) {
        std::wcerr << L"Usage: file_change_monitor <directory>\n";
        return 2;
    }

    try {
        auto& loop = ActionLoop::get_instance();
        DirectoryWatcher watcher(loop.get_executor(), argv[1], [&loop](FileChange change) {
            loop.push_action(std::make_unique<FileChangeLogAction>(std::move(change)));
        });
        watcher.start();
        std::wcout << L"Watching " << argv[1]
                   << L" for completed changes. Press Enter to stop.\n"
                   << L"This sample cannot block or undo file operations; use a Minifilter for enforcement.\n";
        std::wstring line;
        std::getline(std::wcin, line);
        watcher.stop();
    } catch (const std::exception& error) {
        std::cerr << "File monitor failed: " << error.what() << '\n';
        return 1;
    }
    return 0;
}