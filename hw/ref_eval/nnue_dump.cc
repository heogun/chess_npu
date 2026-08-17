/*
 * nnue_dump.cc — SF18 (.nnue) 파서 + 자연 레이아웃 + round-trip 검증 도구 (M1)
 * 포맷 기준: src/nnue/nnue_common.h, network.cpp, nnue_feature_transformer.h,
 *            layers/{affine_transform,affine_transform_sparse_input}.h
 * 빌드: g++ -O2 -std=c++17 -o nnue_dump nnue_dump.cc
 * 사용: ./nnue_dump <file.nnue>
 */

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static constexpr std::uint32_t Version = 0x7AF32F20u;

static constexpr int  OutScale_Big      = 1024;
static constexpr int  OutScale_Small    = 128;
static constexpr int  PSQInputDim       = 22528;
static constexpr int  ThrInputDim       = 79856;
static constexpr int  PSQTBuckets       = 8;
static constexpr int  LayerStacks       = 8;
static constexpr int  FC0_OUT           = 16;
static constexpr int  FC1_IN            = 30;
static constexpr int  FC1_OUT           = 32;
static constexpr int  FC2_IN            = 32;
static constexpr int  FC2_OUT           = 1;
static constexpr int  MaxSimdWidth      = 32;
static constexpr int  ChunkSize         = 4;

static inline int ceil_to_multiple(int n, int base) { return (n + base - 1) / base * base; }

struct ByteStream {
    const std::uint8_t* data;
    size_t              size;
    size_t              pos = 0;
    bool                read(void* out, size_t n) {
        if (pos + n > size) return false;
        std::memcpy(out, data + pos, n);
        pos += n;
        return true;
    }
    template<typename T> bool readLE(T& v) {
        static_assert(std::is_trivially_copyable_v<T>);
        if (pos + sizeof(T) > size) return false;
        std::memcpy(&v, data + pos, sizeof(T));
        pos += sizeof(T);
        return true;
    }
};

static constexpr const char* Leb128Magic  = "COMPRESSED_LEB128";
static constexpr size_t      Leb128MagicN = 17;

static bool read_leb_value(ByteStream& s, std::int32_t& out) {
    std::int32_t result = 0;
    int          shift  = 0;
    std::uint8_t byte;
    while (true) {
        if (!s.read(&byte, 1)) return false;
        result |= (byte & 0x7f) << (shift % 32);
        shift += 7;
        if ((byte & 0x80) == 0) break;
    }
    out = (shift >= 32 || (byte & 0x40) == 0) ? result : result | ~((1 << shift) - 1);
    return true;
}

struct LebBlock {
    ByteStream&   s;
    std::uint32_t bytes_left;
    size_t        start;

    LebBlock(ByteStream& s_, const char* what) : s(s_), start(s_.pos), bytes_left(0) {
        char magic[Leb128MagicN];
        if (!s.read(magic, Leb128MagicN) || std::memcmp(magic, Leb128Magic, Leb128MagicN) != 0) {
            fprintf(stderr, "  [%s] bad magic at pos %zu (got %.17s)\n", what, start, magic);
            return;
        }
        s.readLE(bytes_left);
        fprintf(stderr, "  [%s] LEB block at %zu, %u bytes\n", what, start, bytes_left);
    }
    bool ok() const { return bytes_left != 0 || s.pos > start; }
    template<typename T>
    bool consume(T* out, size_t count) {
        for (size_t i = 0; i < count; ++i) {
            std::int32_t v;
            if (!read_leb_value(s, v)) return false;
            out[i] = static_cast<T>(v);
        }
        return true;
    }
};

// FC 레이어: SF 직렬화는 biases=int32(LittleEndian) + weights=int8(LittleEndian, 스크램블 순서)
// 자연(스크램블 해제) 순서로 저장한다: fwd에서 w[i*outDim+j] 형태로 접근 가능.
struct LayerWeights {
    std::vector<std::int32_t> biases;    // [outDim]
    std::vector<std::int8_t>  weights;   // [outDim * paddedIn], 자연 순서
    int inDim, outDim, paddedIn;
};

static inline int scrambled_index(int i, int paddedIn, int outDim) {
    return (i / ChunkSize) % (paddedIn / ChunkSize) * outDim * ChunkSize
         + i / paddedIn * ChunkSize + i % ChunkSize;
}

struct FTWeights {
    std::vector<std::int16_t> biases;
    std::vector<std::int16_t> weights;       // [hd * PSQInputDim]
    std::vector<std::int8_t>  threatWeights; // [hd * ThrInputDim], big 전용
    std::vector<std::int32_t> psqtWeights;   // [PSQInputDim * 8]
    std::vector<std::int32_t> threatPsqt;    // [ThrInputDim * 8], big 전용
    int                       hd;
    bool                      useThreats;
    std::uint32_t             fileHash = 0;
    std::uint32_t             expectHash = 0;
};

struct NetFile {
    std::uint32_t fileVersion, fileHash;
    std::string   desc;
    FTWeights     ft;
    std::vector<std::uint32_t>     stackHash;   // [LayerStacks] 아키텍처 해시 (파일에 기록)
    std::vector<LayerWeights> fc0, fc1, fc2;
};

static bool parse_file(const std::string& path, NetFile& net) {
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return false;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::vector<std::uint8_t> buf(sz);
    fread(buf.data(), 1, sz, f);
    fclose(f);

    ByteStream s{buf.data(), buf.size()};

    if (!s.readLE(net.fileVersion) || !s.readLE(net.fileHash)) return false;
    std::uint32_t descLen = 0;
    if (!s.readLE(descLen)) return false;
    net.desc.resize(descLen);
    if (!s.read(net.desc.data(), descLen)) return false;

    net.ft.useThreats = (sz > 20'000'000);
    net.ft.hd         = net.ft.useThreats ? OutScale_Big : OutScale_Small;
    int HD = net.ft.hd;

    // FT 컴포넌트 해시 — Detail::read_parameters 가 네트워크/FT/각 스택 앞에 u32 해시 기록
    if (!s.readLE(net.ft.fileHash)) return false;
    net.ft.expectHash = (net.ft.useThreats ? 0x8f234cb8u : 0x7f234cb8u)
                      ^ (uint32_t(HD) * 2);

    {
        LebBlock blk(s, "biases");
        net.ft.biases.resize(size_t(HD));
        if (!blk.consume(net.ft.biases.data(), HD)) return false;
    }
    if (net.ft.useThreats) {
        net.ft.threatWeights.resize(size_t(HD) * ThrInputDim);
        if (!s.read(net.ft.threatWeights.data(), net.ft.threatWeights.size())) return false;
    }
    {
        LebBlock blk(s, "ft_weights");
        net.ft.weights.resize(size_t(HD) * PSQInputDim);
        if (!blk.consume(net.ft.weights.data(), net.ft.weights.size())) return false;
    }
    {
        LebBlock blk(s, "psqt");
        if (net.ft.useThreats) {
            net.ft.threatPsqt.resize(size_t(ThrInputDim) * PSQTBuckets);
            net.ft.psqtWeights.resize(size_t(PSQInputDim) * PSQTBuckets);
            if (!blk.consume(net.ft.threatPsqt.data(), net.ft.threatPsqt.size())) return false;
            if (!blk.consume(net.ft.psqtWeights.data(), net.ft.psqtWeights.size())) return false;
        } else {
            net.ft.psqtWeights.resize(size_t(PSQInputDim) * PSQTBuckets);
            if (!blk.consume(net.ft.psqtWeights.data(), net.ft.psqtWeights.size())) return false;
        }
    }

    for (int i = 0; i < LayerStacks; ++i) {
        std::uint32_t archHash = 0;
        if (!s.readLE(archHash)) return false;
        net.stackHash.push_back(archHash);
        auto read_layer = [&](LayerWeights& lw, int inDim, int outDim) {
            lw.inDim = inDim;
            lw.outDim = outDim;
            lw.paddedIn = ceil_to_multiple(inDim, MaxSimdWidth);
            lw.biases.resize(lw.outDim);
            lw.weights.resize(size_t(lw.outDim) * lw.paddedIn);
            if (!s.read(lw.biases.data(), lw.biases.size() * 4)) return false;
            std::vector<std::int8_t> raw(lw.weights.size());
            if (!s.read(raw.data(), raw.size())) return false;
            for (size_t k = 0; k < raw.size(); ++k)
                lw.weights[size_t(scrambled_index(int(k), lw.paddedIn, lw.outDim))] = raw[k];
            return true;
        };
        LayerWeights a, b, c;
        if (!read_layer(a, HD, FC0_OUT)) return false;
        if (!read_layer(b, FC1_IN, FC1_OUT)) return false;
        if (!read_layer(c, FC2_IN, FC2_OUT)) return false;
        net.fc0.push_back(std::move(a));
        net.fc1.push_back(std::move(b));
        net.fc2.push_back(std::move(c));
    }

    if (s.pos != s.size)
        fprintf(stderr, "WARN: %zu trailing bytes (%zu/%zu consumed)\n", s.size - s.pos, s.pos, s.size);
    else
        printf("OK: EOF exact (%zu/%zu bytes)\n", s.pos, s.size);
    return s.pos == s.size;
}

static void write_leb_value(std::vector<std::uint8_t>& out, std::int32_t v) {
    while (true) {
        std::uint8_t byte = v & 0x7f;
        v >>= 7;
        if ((byte & 0x40) == 0 ? v == 0 : v == -1) {
            out.push_back(byte);
            break;
        }
        out.push_back(byte | 0x80);
    }
}

static void write_leb_block(std::vector<std::uint8_t>& out, const std::int32_t* vals, size_t n) {
    out.insert(out.end(), Leb128Magic, Leb128Magic + Leb128MagicN);
    std::uint32_t byte_count = 0;
    for (size_t i = 0; i < n; ++i) {
        std::int32_t v = vals[i];
        std::uint8_t byte;
        do {
            byte = v & 0x7f;
            v >>= 7;
            byte_count++;
        } while ((byte & 0x40) == 0 ? v != 0 : v != -1);
    }
    out.push_back(byte_count & 0xff);
    out.push_back((byte_count >> 8) & 0xff);
    out.push_back((byte_count >> 16) & 0xff);
    out.push_back((byte_count >> 24) & 0xff);
    for (size_t i = 0; i < n; ++i) write_leb_value(out, vals[i]);
}

static std::vector<std::uint8_t> reserialize(const NetFile& net) {
    std::vector<std::uint8_t> out;
    auto u32 = [&](std::uint32_t v) {
        out.push_back(v & 0xff); out.push_back((v >> 8) & 0xff);
        out.push_back((v >> 16) & 0xff); out.push_back((v >> 24) & 0xff);
    };
    u32(net.fileVersion);
    u32(net.fileHash);
    u32(uint32_t(net.desc.size()));
    out.insert(out.end(), net.desc.begin(), net.desc.end());

    u32(net.ft.fileHash);
    {
        std::vector<std::int32_t> tmp(net.ft.biases.begin(), net.ft.biases.end());
        write_leb_block(out, tmp.data(), tmp.size());
    }
    if (net.ft.useThreats) {
        out.insert(out.end(), net.ft.threatWeights.begin(), net.ft.threatWeights.end());
        std::vector<std::int32_t> tmp(net.ft.weights.begin(), net.ft.weights.end());
        write_leb_block(out, tmp.data(), tmp.size());
        std::vector<std::int32_t> tmp2(net.ft.threatPsqt.begin(), net.ft.threatPsqt.end());
        tmp2.insert(tmp2.end(), net.ft.psqtWeights.begin(), net.ft.psqtWeights.end());
        write_leb_block(out, tmp2.data(), tmp2.size());
    } else {
        std::vector<std::int32_t> tmp(net.ft.weights.begin(), net.ft.weights.end());
        write_leb_block(out, tmp.data(), tmp.size());
        std::vector<std::int32_t> tmp2(net.ft.psqtWeights.begin(), net.ft.psqtWeights.end());
        write_leb_block(out, tmp2.data(), tmp2.size());
    }

    for (int i = 0; i < LayerStacks; ++i) {
        u32(net.stackHash[i]);
        for (const LayerWeights* lw : {&net.fc0[i], &net.fc1[i], &net.fc2[i]}) {
            out.insert(out.end(), (const char*)lw->biases.data(),
                       (const char*)lw->biases.data() + lw->biases.size() * sizeof(int32_t));
            for (size_t k = 0; k < lw->weights.size(); ++k) {
                std::int8_t w = lw->weights[size_t(scrambled_index(int(k), lw->paddedIn, lw->outDim))];
                out.push_back(std::uint8_t(w));
            }
        }
    }
    return out;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <file.nnue>\n", argv[0]);
        return 1;
    }
    NetFile net;
    if (!parse_file(argv[1], net)) {
        fprintf(stderr, "parse failed: %s\n", argv[1]);
        return 1;
    }
    printf("== %s ==\n", argv[1]);
    printf("Version = 0x%08X %s\n", net.fileVersion, net.fileVersion == Version ? "(match)" : "(MISMATCH!)");
    printf("Hash    = 0x%08X\n", net.fileHash);
    printf("Desc    = %s\n", net.desc.c_str());
    printf("FT hash = 0x%08X %s (expect 0x%08X)\n",
           net.ft.fileHash,
           net.ft.fileHash == net.ft.expectHash ? "(match)" : "(MISMATCH!)",
           net.ft.expectHash);

    std::vector<std::uint8_t> re = reserialize(net);
    if (argc > 2) {
        FILE* g = fopen(argv[2], "wb");
        fwrite(re.data(), 1, re.size(), g);
        fclose(g);
    }
    FILE* f = fopen(argv[1], "rb");
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fclose(f);
    bool exact = re.size() == size_t(sz);
    if (exact) {
        FILE* a = fopen(argv[1], "rb");
        std::vector<std::uint8_t> orig(sz);
        fread(orig.data(), 1, sz, a);
        fclose(a);
        exact = std::memcmp(orig.data(), re.data(), sz) == 0;
    }
    printf("ROUND-TRIP: %s (%zu vs %zu bytes)\n",
           exact ? "EXACT - loader 구조 정확성 증명" : "DIFFERS", re.size(), size_t(sz));

    const FTWeights& ft = net.ft;
    printf("\n-- HW DDR layout --\n");
    printf("FT biases      %8zu B (int16 x %d)\n", ft.biases.size() * 2, ft.hd);
    printf("FT weights     %8zu B (int16 x %zu)\n", ft.weights.size() * 2, ft.weights.size());
    if (ft.useThreats)
        printf("FT threat      %8zu B (int8  x %zu)\n", ft.threatWeights.size(), ft.threatWeights.size());
    printf("FT psqt        %8zu B (int32 x %zu)\n", ft.psqtWeights.size() * 4, ft.psqtWeights.size());
    if (ft.useThreats)
        printf("FT thrpsqt     %8zu B (int32 x %zu)\n", ft.threatPsqt.size() * 4, ft.threatPsqt.size());
    for (int i = 0; i < LayerStacks; ++i)
        printf("stack[%d] fc_0 %7zu B | fc_1 %6zu B | fc_2 %5zu B\n",
               i, net.fc0[i].weights.size(), net.fc1[i].weights.size(), net.fc2[i].weights.size());
    return 0;
}