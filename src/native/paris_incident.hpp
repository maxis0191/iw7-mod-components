#pragma once
#include <cstdint>
namespace paris_incident
{
    // No packet retries, payload copies or changes to engine return values.
    void send_result(int length, int result, int error, const void* address) noexcept;
    // Called by the existing upstream drop stub, before native cleanup.
    void client_drop(const void* client, const char* reason, bool tell) noexcept;
}
