#pragma once
#include <windows.h>
#include <bcrypt.h>
#include <cstring>
#include <string>
#include <string_view>
#pragma comment(lib, "bcrypt.lib")

namespace owner_cheats::crypto
{
    // Windows CNG P-256 blobs; signatures are fixed 64-byte IEEE P1363 r||s.
    class key
    {
        BCRYPT_ALG_HANDLE algorithm_{};
        BCRYPT_KEY_HANDLE key_{};
        bool private_{};
    public:
        key() = default;
        key(const key&) = delete;
        key& operator=(const key&) = delete;
        ~key() { clear(); }
        void clear()
        {
            if (key_) BCryptDestroyKey(key_);
            if (algorithm_) BCryptCloseAlgorithmProvider(algorithm_, 0);
            key_ = nullptr; algorithm_ = nullptr; private_ = false;
        }
        bool load(std::string_view blob, bool secret)
        {
            clear();
            if (blob.size() != (secret ? 104u : 72u)) return false;
            BCRYPT_ECCKEY_BLOB header{};
            std::memcpy(&header, blob.data(), sizeof(header));
            if (header.cbKey != 32 || header.dwMagic != static_cast<ULONG>(secret ? BCRYPT_ECDSA_PRIVATE_P256_MAGIC : BCRYPT_ECDSA_PUBLIC_P256_MAGIC)) return false;
            if (BCryptOpenAlgorithmProvider(&algorithm_, BCRYPT_ECDSA_P256_ALGORITHM, nullptr, 0) < 0) return false;
            if (BCryptImportKeyPair(algorithm_, nullptr, secret ? BCRYPT_ECCPRIVATE_BLOB : BCRYPT_ECCPUBLIC_BLOB,
                &key_, reinterpret_cast<PUCHAR>(const_cast<char*>(blob.data())), static_cast<ULONG>(blob.size()), 0) < 0)
            { clear(); return false; }
            private_ = secret;
            return true;
        }
        bool valid() const { return key_ != nullptr; }
        std::string sign(std::string_view message) const
        {
            if (!key_ || !private_) return {};
            const auto hash = digest(message);
            if (hash.size() != 32) return {};
            std::string signature(64, '\0'); ULONG length{};
            if (BCryptSignHash(key_, nullptr, reinterpret_cast<PUCHAR>(const_cast<char*>(hash.data())), 32,
                reinterpret_cast<PUCHAR>(signature.data()), 64, &length, 0) < 0 || length != 64) return {};
            return signature;
        }
        bool verify(std::string_view message, std::string_view signature) const
        {
            if (!key_ || signature.size() != 64) return false;
            const auto hash = digest(message);
            return hash.size() == 32 && BCryptVerifySignature(key_, nullptr,
                reinterpret_cast<PUCHAR>(const_cast<char*>(hash.data())), 32,
                reinterpret_cast<PUCHAR>(const_cast<char*>(signature.data())), 64, 0) >= 0;
        }
        static std::string digest(std::string_view message)
        {
            BCRYPT_ALG_HANDLE algorithm{};
            if (message.size() > 1024 || BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) return {};
            std::string out(32, '\0');
            const auto status = BCryptHash(algorithm, nullptr, 0,
                reinterpret_cast<PUCHAR>(const_cast<char*>(message.data())), static_cast<ULONG>(message.size()),
                reinterpret_cast<PUCHAR>(out.data()), 32);
            BCryptCloseAlgorithmProvider(algorithm, 0);
            return status >= 0 ? out : std::string{};
        }
    };
}
