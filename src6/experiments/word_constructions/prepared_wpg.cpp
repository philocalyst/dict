// WPG2 reader: prepare unchanged v4 Jobs once, then decode exact source pages.
// The constructor runs in this process with bounded page buffers/registers.
#define WREG_NO_MAIN
#include "register_decode.cpp"
#include "prepared_jobs.h"

#include <chrono>
#include <cstring>
#include <iostream>
#include <limits>

static constexpr size_t PAGE = 65536;
static constexpr size_t MAX_RAW = 32 * 1024 * 1024;
static constexpr size_t MAX_FRAME = 64 * 1024 * 1024;

static uint32_t crc_update(uint32_t crc, const unsigned char *data, size_t len) {
    static const auto table = [] {
        uint32_t values[256] = {};
        for (unsigned i=0;i<256;++i) {
            uint32_t x=i;
            for (int j=0;j<8;++j) x=(x>>1) ^ ((x&1) ? 0xedb88320u : 0u);
            values[i]=x;
        }
        struct Table { uint32_t values[256]; } result;
        std::copy(values,values+256,result.values);
        return result;
    }();
    for (size_t i=0;i<len;++i) crc=table.values[(crc^data[i])&255]^(crc>>8);
    return crc;
}
static uint32_t crc32(const string& data) {
    return crc_update(0xffffffffu,reinterpret_cast<const unsigned char*>(data.data()),data.size())^0xffffffffu;
}
static uint32_t crc_bytes(const unsigned char *data,size_t len) {
    return crc_update(0xffffffffu,data,len)^0xffffffffu;
}
static uint32_t u32(const std::vector<unsigned char>& bytes,size_t at) {
    if (at+4>bytes.size()) throw std::runtime_error("short u32");
    return uint32_t(bytes[at]) | (uint32_t(bytes[at+1])<<8) | (uint32_t(bytes[at+2])<<16) | (uint32_t(bytes[at+3])<<24);
}
static size_t varint(const std::vector<unsigned char>& bytes,size_t& at) {
    size_t value=0;
    for (unsigned shift=0;shift<=63;shift+=7) {
        if (at>=bytes.size()) throw std::runtime_error("short varint");
        unsigned c=bytes[at++];
        if (shift==63 && (c&127)>1) throw std::runtime_error("varint overflow");
        value |= size_t(c&127)<<shift;
        if (!(c&128)) return value;
    }
    throw std::runtime_error("bad varint");
}
static std::vector<unsigned char> read_file(const string& path) {
    std::ifstream in(path,std::ios::binary|std::ios::ate);
    if (!in) throw std::runtime_error("open archive failed");
    auto length=in.tellg();
    if (length<0 || static_cast<uint64_t>(length)>MAX_FRAME+MAX_RAW/64+4096)
        throw std::runtime_error("archive bound");
    std::vector<unsigned char> bytes(static_cast<size_t>(length));
    in.seekg(0);
    if (!bytes.empty()) in.read(reinterpret_cast<char*>(bytes.data()),length);
    if (!in && !bytes.empty()) throw std::runtime_error("read archive failed");
    return bytes;
}
static void write_file(const string& path,const string& bytes) {
    std::ofstream out(path,std::ios::binary);
    if (!out) throw std::runtime_error("open output failed");
    out.write(bytes.data(),static_cast<std::streamsize>(bytes.size()));
    if (!out) throw std::runtime_error("write failed");
}

struct Archive {
    std::vector<unsigned char> bytes;
    std::vector<size_t> lengths;
    std::vector<size_t> offsets;
    std::vector<uint32_t> checksums;
    size_t raw_size=0, frame_at=0, frame_size=0, index_bytes=0;
    uint32_t global_crc=0;
    unsigned mode=0;

    explicit Archive(const string& path):bytes(read_file(path)) {
        if (bytes.size()<6 || std::memcmp(bytes.data(),"WPG2",4)) throw std::runtime_error("magic");
        mode=bytes[4];
        if (mode>3) throw std::runtime_error("mode");
        size_t at=5;
        raw_size=varint(bytes,at);
        size_t page_size=varint(bytes,at),count=varint(bytes,at);
        if (raw_size>MAX_RAW || page_size!=PAGE || count!=(raw_size+PAGE-1)/PAGE)
            throw std::runtime_error("page geometry");
        const size_t index_start=at;
        offsets.push_back(0);
        for (size_t i=0;i<count;++i) {
            size_t n=varint(bytes,at);
            if (n>2*PAGE || at+4>bytes.size() || n>2*MAX_RAW-offsets.back())
                throw std::runtime_error("page index");
            lengths.push_back(n);
            checksums.push_back(u32(bytes,at)); at+=4;
            offsets.push_back(offsets.back()+n);
        }
        index_bytes=at-index_start;
        if (at+4>bytes.size() || crc_bytes(bytes.data(),at)!=u32(bytes,at))
            throw std::runtime_error("header CRC");
        at+=4;
        frame_size=varint(bytes,at);
        if (frame_size>MAX_FRAME || at+frame_size+4!=bytes.size())
            throw std::runtime_error("frame length");
        frame_at=at;
        global_crc=u32(bytes,at+frame_size);
    }
    const unsigned char* frame() const { return bytes.data()+frame_at; }
    size_t pages() const { return lengths.size(); }
};

struct Reader {
    Archive archive;
    void *prepared=nullptr;
    size_t transformed_bytes=0,entropy_jobs=0,model_reserved=0,job_directory=0;
    size_t scratch_peak=0;

    explicit Reader(const string& path):archive(path) {
        if (wpg_prepare(archive.frame(),archive.frame_size,&prepared))
            throw std::runtime_error("native v4 model preparation failed");
        if (wpg_stats(prepared,&transformed_bytes,&entropy_jobs,&model_reserved,&job_directory) ||
            transformed_bytes!=archive.offsets.back()) {
            wpg_close(prepared); prepared=nullptr;
            throw std::runtime_error("transformed geometry");
        }
    }
    ~Reader() { wpg_close(prepared); }
    Reader(const Reader&)=delete;
    Reader& operator=(const Reader&)=delete;

    struct Page { string bytes; size_t jobs; };
    Page read(size_t index) {
        if (index>=archive.pages()) throw std::runtime_error("page index");
        const size_t n=archive.lengths[index];
        string transformed(n,'\0');
        size_t jobs=0;
        if (wpg_read(prepared,archive.offsets[index],n,
                     reinterpret_cast<unsigned char*>(transformed.data()),transformed.size(),&jobs))
            throw std::runtime_error("native v4 payload decode failed");
        size_t live=transformed.size();
        if (archive.mode>=2) transformed=process_segment(transformed,true);
        live+=transformed.size();
        if (archive.mode>=1) transformed=process_segment(transformed,false);
        live+=transformed.size();
        scratch_peak=std::max(scratch_peak,live);
        if (transformed.size()!=std::min(PAGE,archive.raw_size-index*PAGE) ||
            crc32(transformed)!=archive.checksums[index])
            throw std::runtime_error("source page CRC or length");
        return {std::move(transformed),jobs};
    }
    void decode_all(const string& path) {
        // A bad later page or global CRC must not publish a partial result.
        // mkstemp places the temporary file alongside the destination, so
        // the final rename is atomic on the same filesystem.
        std::vector<char> temp(path.begin(),path.end());
        for (char c : string(".tmp.XXXXXX")) temp.push_back(c);
        temp.push_back('\0');
        int fd=mkstemp(temp.data());
        if (fd<0) throw std::runtime_error("open temporary output failed");
        std::FILE *out=fdopen(fd,"wb");
        if (!out) { close(fd); std::remove(temp.data()); throw std::runtime_error("fdopen failed"); }
        try {
            uint32_t crc=0xffffffffu;
            for (size_t i=0;i<archive.pages();++i) {
                auto page=read(i);
                if (std::fwrite(page.bytes.data(),1,page.bytes.size(),out)!=page.bytes.size())
                    throw std::runtime_error("write failed");
                crc=crc_update(crc,reinterpret_cast<const unsigned char*>(page.bytes.data()),page.bytes.size());
            }
            if ((crc^0xffffffffu)!=archive.global_crc) throw std::runtime_error("global CRC");
            if (std::fclose(out)!=0) { out=nullptr; throw std::runtime_error("close output failed"); }
            out=nullptr;
            if (std::rename(temp.data(),path.c_str())!=0) throw std::runtime_error("publish output failed");
        } catch (...) {
            if (out) std::fclose(out);
            std::remove(temp.data());
            throw;
        }
    }
};

static long long ns(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now()-start).count();
}

int main(int argc,char** argv) {
    try {
        if (argc<4) throw std::runtime_error("usage: prepared_wpg decode|query|bench ARCHIVE OUT [--index N] [--measure 1 --quiet-gate WORDZIP-READER-QUIET]");
        string operation=argv[1], input=argv[2], output=argv[3];
        size_t index=0;
        bool measured=false,quiet=false;
        for (int i=4;i<argc;i+=2) {
            if (i+1>=argc) throw std::runtime_error("missing option value");
            string option=argv[i],value=argv[i+1];
            if (option=="--index") index=std::stoull(value);
            else if (option=="--measure") measured=value=="1";
            else if (option=="--quiet-gate") quiet=value=="WORDZIP-READER-QUIET";
            else throw std::runtime_error("unknown option");
        }
        if (measured && !quiet) throw std::runtime_error("quiet timing gate");
        const auto begin=std::chrono::steady_clock::now();
        Reader reader(input);
        const auto prepare_ns=measured ? ns(begin) : 0;
        if (operation=="decode") {
            const auto decode_start=std::chrono::steady_clock::now();
            reader.decode_all(output);
            std::cout << "{\"frame_bytes\":"<<reader.archive.bytes.size()<<",\"raw_bytes\":"<<reader.archive.raw_size
                      <<",\"pages\":"<<reader.archive.pages()<<",\"payload_jobs\":"<<reader.entropy_jobs
                      <<",\"prepare_ns\":"<<prepare_ns<<",\"decode_ns\":"<<(measured?ns(decode_start):0)<<"}\n";
        } else if (operation=="query") {
            auto page=reader.read(index);
            write_file(output,page.bytes);
            std::cout << "{\"page\":"<<index<<",\"bytes\":"<<page.bytes.size()<<",\"payload_jobs\":"<<page.jobs
                      <<",\"crc32\":"<<crc32(page.bytes)<<"}\n";
        } else if (operation=="bench") {
            if (reader.archive.pages()==0) throw std::runtime_error("empty benchmark");
            const auto query_start=std::chrono::steady_clock::now();
            uint64_t checksum=1469598103934665603ull;
            size_t total_bytes=0,total_jobs=0;
            for (size_t access=0;access<256;++access) {
                size_t chosen=access%3==0 ? 0 : (access%3==1 ? reader.archive.pages()/2 : reader.archive.pages()-1);
                auto page=reader.read(chosen);
                checksum=(checksum^crc32(page.bytes))*1099511628211ull;
                total_bytes+=page.bytes.size(); total_jobs+=page.jobs;
            }
            const auto query_ns=measured ? ns(query_start) : 0;
            std::ofstream out(output);
            if (!out) throw std::runtime_error("open stats failed");
            out << "{\"protocol\":\"WPG2-PREPARED-PAGE/1\",\"timing_enabled\":"<<(measured?"true":"false")
                <<",\"frame_bytes\":"<<reader.archive.bytes.size()<<",\"raw_bytes\":"<<reader.archive.raw_size
                <<",\"transformed_bytes\":"<<reader.transformed_bytes<<",\"page_bytes\":"<<PAGE
                <<",\"pages\":"<<reader.archive.pages()<<",\"payload_jobs\":"<<reader.entropy_jobs
                <<",\"prepare_ns\":"<<prepare_ns<<",\"decode_256_ns\":"<<query_ns
                <<",\"access_count\":256,\"decoded_bytes\":"<<total_bytes<<",\"decoded_jobs\":"<<total_jobs
                <<",\"checksum\":"<<checksum<<",\"model_reserved_bytes\":"<<reader.model_reserved
                <<",\"job_directory_bytes\":"<<reader.job_directory
                <<",\"page_index_bytes\":"<<reader.archive.index_bytes
                <<",\"retained_archive_bytes\":"<<reader.archive.bytes.size()
                <<",\"constructor_scratch_peak_bytes\":"<<reader.scratch_peak<<",\"mode\":"<<reader.archive.mode
                <<",\"accounting\":\"prepare includes archive read, header/index parse, all model deltas and immutable Jobs; query includes touched payload jobs, constructor, page CRC, and owned output\"}\n";
            out.close();
            std::ifstream back(output);
            std::cout << back.rdbuf();
        } else throw std::runtime_error("unknown operation");
    } catch (const std::exception& e) {
        std::fprintf(stderr,"prepared_wpg: %s\n",e.what());
        return 1;
    }
}
