#include "ActionLoop.hpp"

#include <exception>
#include <iostream>
#include <stdexcept>
#include <utility>

#include <boost/asio/co_spawn.hpp>

namespace asio = boost::asio;

ActionLoop::ActionLoop()
    : work_guard_(asio::make_work_guard(io_context_))
    , thread_([this] { io_context_.run(); })
{
}

ActionLoop::~ActionLoop()
{
    // Let run() return once the queued actions are done, so no output is lost.
    stopping_.store(true, std::memory_order_relaxed);
    work_guard_.reset();
    if (thread_.joinable()) {
        thread_.join();
    }
}

ActionLoop& ActionLoop::get_instance()
{
    static ActionLoop instance;
    return instance;
}

asio::io_context::executor_type ActionLoop::get_executor() noexcept
{
    return io_context_.get_executor();
}

asio::awaitable<void> ActionLoop::execute_action(std::shared_ptr<IAction> action)
{
    co_await action->execute_async();
}

void ActionLoop::push_action(std::unique_ptr<IAction> action)
{
    if (!action) {
        throw std::invalid_argument("ActionLoop does not accept a null action");
    }
    if (stopping_.load(std::memory_order_relaxed)) {
        throw std::runtime_error("ActionLoop is stopping");
    }

    auto shared_action = std::shared_ptr<IAction>(std::move(action));
    asio::co_spawn(
        io_context_,
        execute_action(std::move(shared_action)),
        [](std::exception_ptr error) {
            if (error) {
                report_exception("Action", error);
            }
        });
}

void report_exception(const char* context, std::exception_ptr error) noexcept
{
    try {
        std::rethrow_exception(error);
    } catch (const std::exception& exception) {
        std::cerr << context << " failed: " << exception.what() << '\n';
    } catch (...) {
        std::cerr << context << " failed with an unknown exception\n";
    }
}
