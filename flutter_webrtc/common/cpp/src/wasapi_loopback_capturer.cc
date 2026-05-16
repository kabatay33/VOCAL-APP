#include "wasapi_loopback_capturer.h"

#ifdef _WIN32

#include <Functiondiscoverykeys_devpkey.h>
#include <avrt.h>
#include <combaseapi.h>
#include <mmdeviceapi.h>
#include <propsys.h>
#include <wrl/client.h>
#include <wrl/implements.h>

#include <algorithm>
#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <iostream>
#include <sstream>

namespace flutter_webrtc_plugin {

// Release build'de stdout buffering nedeniyle log'lar görünmüyor.
// Dosyaya yazalım + her seferinde flush yapalım.
void WasapiLog(const char* fmt, ...) {
  static FILE* log_file = nullptr;
  static bool tried_open = false;
  if (!log_file && !tried_open) {
    tried_open = true;
    // Exe'nin bulunduğu klasörü bul, log'u oraya yaz (CWD'den bağımsız)
    char exe_path[MAX_PATH] = {0};
    DWORD len = ::GetModuleFileNameA(nullptr, exe_path, MAX_PATH);
    if (len > 0 && len < MAX_PATH) {
      // exe_path'in son '\\' indirip yerine log dosya adını ekle
      char* last_slash = std::strrchr(exe_path, '\\');
      if (last_slash) {
        *(last_slash + 1) = '\0';
        std::string log_path = std::string(exe_path) + "wasapi_debug.log";
        fopen_s(&log_file, log_path.c_str(), "a");
      }
    }
    if (!log_file) {
      // Fallback: kullanıcı temp klasörü
      char temp[MAX_PATH] = {0};
      if (::GetTempPathA(MAX_PATH, temp) > 0) {
        std::string log_path = std::string(temp) + "wasapi_debug.log";
        fopen_s(&log_file, log_path.c_str(), "a");
      }
    }
  }
  if (!log_file) return;
  va_list args;
  va_start(args, fmt);
  std::vfprintf(log_file, fmt, args);
  std::fputc('\n', log_file);
  std::fflush(log_file);
  va_end(args);
  // Konsola da yaz (PowerShell'den çalıştırıldığında görünür)
  va_start(args, fmt);
  std::vfprintf(stderr, fmt, args);
  std::fputc('\n', stderr);
  std::fflush(stderr);
  va_end(args);
}

// -----------------------------------------------------------------------------
// Process Loopback Capture (Windows 10 build 20348 / 21H2 ve sonrası)
// Headerlar bazı Visual Studio SDK sürümlerinde yok — manuel tanımlıyoruz.
// -----------------------------------------------------------------------------
#ifndef VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK
#define VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK L"VAD\\Process_Loopback"
#endif

#ifndef AUDIOCLIENT_ACTIVATION_TYPE_DEFINED
#define AUDIOCLIENT_ACTIVATION_TYPE_DEFINED
typedef enum AUDIOCLIENT_ACTIVATION_TYPE {
  AUDIOCLIENT_ACTIVATION_TYPE_DEFAULT,
  AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK
} AUDIOCLIENT_ACTIVATION_TYPE;

typedef enum PROCESS_LOOPBACK_MODE {
  PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE,
  PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE
} PROCESS_LOOPBACK_MODE;

typedef struct AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS {
  DWORD TargetProcessId;
  PROCESS_LOOPBACK_MODE ProcessLoopbackMode;
} AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS;

typedef struct AUDIOCLIENT_ACTIVATION_PARAMS {
  AUDIOCLIENT_ACTIVATION_TYPE ActivationType;
  union {
    AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS ProcessLoopbackParams;
  } DUMMYUNIONNAME;
} AUDIOCLIENT_ACTIVATION_PARAMS;
#endif

namespace {

// WebRTC frame süresi 10 ms — bu kadar frame topla, sonra callback'le ver
constexpr int kFrameDurationMs = 10;

void EnsureComInit() { ::CoInitializeEx(nullptr, COINIT_MULTITHREADED); }

// Process Loopback için manuel format (loopback mix format'ını alamadığımız için)
WAVEFORMATEXTENSIBLE MakeProcessLoopbackFormat() {
  WAVEFORMATEXTENSIBLE fmt = {};
  fmt.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
  fmt.Format.nChannels = 2;
  fmt.Format.nSamplesPerSec = 48000;
  fmt.Format.wBitsPerSample = 32;
  fmt.Format.nBlockAlign =
      (fmt.Format.nChannels * fmt.Format.wBitsPerSample) / 8;
  fmt.Format.nAvgBytesPerSec =
      fmt.Format.nSamplesPerSec * fmt.Format.nBlockAlign;
  fmt.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
  fmt.Samples.wValidBitsPerSample = 32;
  fmt.dwChannelMask = SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT;
  fmt.SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
  return fmt;
}

// IActivateAudioInterfaceCompletionHandler — async aktivasyon için.
// FtmBase eklenmesi şart: free-threaded marshaler ile MTA thread'den
// çağrılabilir hale gelir. InhibitFtmBase KULLANMA — yanlış olur.
class CompletionHandler
    : public Microsoft::WRL::RuntimeClass<
          Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
          IActivateAudioInterfaceCompletionHandler,
          Microsoft::WRL::FtmBase> {
 public:
  CompletionHandler() {
    done_event_ = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  }
  ~CompletionHandler() {
    if (done_event_) ::CloseHandle(done_event_);
  }

  HANDLE event() const { return done_event_; }
  HRESULT result() const { return activate_result_; }
  IAudioClient* audio_client() const { return audio_client_.Get(); }

  STDMETHODIMP ActivateCompleted(
      IActivateAudioInterfaceAsyncOperation* op) override {
    HRESULT hr_activate = E_FAIL;
    Microsoft::WRL::ComPtr<IUnknown> punk;
    HRESULT hr = op->GetActivateResult(&hr_activate, &punk);
    if (FAILED(hr)) {
      activate_result_ = hr;
    } else if (FAILED(hr_activate)) {
      activate_result_ = hr_activate;
    } else {
      activate_result_ = punk.As(&audio_client_);
    }
    ::SetEvent(done_event_);
    return S_OK;
  }

 private:
  HANDLE done_event_ = nullptr;
  HRESULT activate_result_ = E_FAIL;
  Microsoft::WRL::ComPtr<IAudioClient> audio_client_;
};

}  // namespace

WasapiLoopbackCapturer::WasapiLoopbackCapturer() = default;

WasapiLoopbackCapturer::~WasapiLoopbackCapturer() { Stop(); }

bool WasapiLoopbackCapturer::Start(FrameCallback callback) {
  if (running_.load()) return true;
  last_error_.clear();

  WasapiLog("[WASAPI] Start() called");

  callback_ = std::move(callback);

  // Tüm WASAPI işlemini worker thread'de MTA olarak yapıyoruz.
  // Flutter platform thread STA'da init edildiği için
  // ActivateAudioInterfaceAsync STA'da E_ILLEGAL_METHOD_CALL hatası veriyor.
  std::promise<bool> init_promise;
  std::future<bool> init_future = init_promise.get_future();

  thread_ = std::thread([this, p = std::move(init_promise)]() mutable {
    // MTA olarak init et — yeni thread, temiz apartment
    HRESULT hr_co = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    bool co_initialized = SUCCEEDED(hr_co);
    WasapiLog("[WASAPI] Worker thread CoInitializeEx: 0x%lx", (unsigned long)hr_co);

    bool init_ok = InitOnWorker();
    p.set_value(init_ok);

    if (init_ok) {
      running_.store(true);
      CaptureLoop();
    }

    // Cleanup worker thread içinde
    if (audio_client_) audio_client_->Stop();
    Cleanup();

    if (co_initialized) ::CoUninitialize();
  });

  bool ok = init_future.get();
  if (!ok) {
    // Thread bitti ya da bitiyor — temizlik için join
    if (thread_.joinable()) thread_.join();
  }
  return ok;
}

bool WasapiLoopbackCapturer::InitOnWorker() {
  auto set_error = [&](const std::string& msg, HRESULT hr) {
    std::stringstream ss;
    ss << msg << " (HRESULT=0x" << std::hex << hr << std::dec << ")";
    last_error_ = ss.str();
    WasapiLog("[WASAPI] ERROR: %s", last_error_.c_str());
  };

  // Önce gerçek sistem render endpoint'inin mix format'ını al.
  // Process loopback bu format'ı bekler; sabit format vermek glitch/distortion
  // yaratıyor.
  WAVEFORMATEX* mix_format = nullptr;
  {
    Microsoft::WRL::ComPtr<IMMDeviceEnumerator> enumerator;
    HRESULT hr = ::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                     CLSCTX_ALL,
                                     IID_PPV_ARGS(&enumerator));
    if (SUCCEEDED(hr)) {
      Microsoft::WRL::ComPtr<IMMDevice> render_endpoint;
      hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole,
                                                &render_endpoint);
      if (SUCCEEDED(hr)) {
        Microsoft::WRL::ComPtr<IAudioClient> temp_client;
        hr = render_endpoint->Activate(__uuidof(IAudioClient), CLSCTX_ALL,
                                        nullptr, &temp_client);
        if (SUCCEEDED(hr)) {
          hr = temp_client->GetMixFormat(&mix_format);
          if (SUCCEEDED(hr) && mix_format) {
            WasapiLog(
                "[WASAPI] Render endpoint mix format: %lu Hz, %u ch, "
                "%u-bit, tag=0x%x",
                (unsigned long)mix_format->nSamplesPerSec,
                mix_format->nChannels, mix_format->wBitsPerSample,
                mix_format->wFormatTag);
          }
        }
      }
    }
  }
  // Mix format alınamadıysa fallback olarak 48kHz stereo float32 kullan
  if (!mix_format) {
    static WAVEFORMATEXTENSIBLE fallback = MakeProcessLoopbackFormat();
    mix_format =
        reinterpret_cast<WAVEFORMATEX*>(::CoTaskMemAlloc(sizeof(fallback)));
    if (mix_format) std::memcpy(mix_format, &fallback, sizeof(fallback));
    WasapiLog("[WASAPI] Mix format alınamadı, fallback (48kHz stereo float32)");
  }
  if (!mix_format) {
    set_error("Mix format alınamadı", E_FAIL);
    return false;
  }

  // Process loopback exclusion — kendi process'imizin (Discord clone) ses
  // çıkışını yakalamadan dışla.
  AUDIOCLIENT_ACTIVATION_PARAMS activate_params = {};
  activate_params.ActivationType =
      AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
  activate_params.ProcessLoopbackParams.TargetProcessId =
      ::GetCurrentProcessId();
  activate_params.ProcessLoopbackParams.ProcessLoopbackMode =
      PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE;

  PROPVARIANT prop_variant = {};
  prop_variant.vt = VT_BLOB;
  prop_variant.blob.cbSize = sizeof(activate_params);
  prop_variant.blob.pBlobData = reinterpret_cast<BYTE*>(&activate_params);

  Microsoft::WRL::ComPtr<CompletionHandler> handler =
      Microsoft::WRL::Make<CompletionHandler>();
  Microsoft::WRL::ComPtr<IActivateAudioInterfaceAsyncOperation> async_op;

  HRESULT hr = ::ActivateAudioInterfaceAsync(
      VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient),
      &prop_variant, handler.Get(), &async_op);
  if (FAILED(hr)) {
    ::CoTaskMemFree(mix_format);
    set_error("ActivateAudioInterfaceAsync failed", hr);
    return false;
  }

  // MTA'da blocking wait — message pump gerektirmez
  ::WaitForSingleObject(handler->event(), 5000);
  hr = handler->result();
  if (FAILED(hr) || !handler->audio_client()) {
    ::CoTaskMemFree(mix_format);
    set_error("Process loopback activation failed", hr);
    return false;
  }

  audio_client_ = handler->audio_client();
  audio_client_->AddRef();

  // Mix format'ı sınıfa devret
  wave_format_ = mix_format;
  mix_format = nullptr;

  // Process loopback Initialize: ShareMode SHARED, sadece LOOPBACK flag,
  // 200ms buffer, periodicity 0.
  constexpr REFERENCE_TIME kRequestedBufferDuration = 2'000'000;
  hr = audio_client_->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                  AUDCLNT_STREAMFLAGS_LOOPBACK,
                                  kRequestedBufferDuration, 0, wave_format_,
                                  nullptr);
  if (FAILED(hr)) {
    set_error("IAudioClient::Initialize failed", hr);
    return false;
  }

  hr = audio_client_->GetService(__uuidof(IAudioCaptureClient),
                                  reinterpret_cast<void**>(&capture_client_));
  if (FAILED(hr)) {
    set_error("GetService failed", hr);
    return false;
  }

  hr = audio_client_->Start();
  if (FAILED(hr)) {
    set_error("IAudioClient::Start failed", hr);
    return false;
  }

  WasapiLog(
      "[WASAPI] Process loopback STARTED (exclude pid=%lu): %lu Hz, %u ch, "
      "%u-bit",
      (unsigned long)::GetCurrentProcessId(),
      (unsigned long)wave_format_->nSamplesPerSec, wave_format_->nChannels,
      wave_format_->wBitsPerSample);
  return true;
}

void WasapiLoopbackCapturer::Stop() {
  // Worker thread loop'u kontrol eder ve kendi cleanup'ını yapar
  running_.store(false);
  if (thread_.joinable()) thread_.join();
}

void WasapiLoopbackCapturer::Cleanup() {
  if (capture_client_) {
    capture_client_->Release();
    capture_client_ = nullptr;
  }
  if (audio_client_) {
    audio_client_->Release();
    audio_client_ = nullptr;
  }
  if (device_) {
    device_->Release();
    device_ = nullptr;
  }
  if (enumerator_) {
    enumerator_->Release();
    enumerator_ = nullptr;
  }
  if (wave_format_) {
    ::CoTaskMemFree(wave_format_);
    wave_format_ = nullptr;
  }
  callback_ = nullptr;
}

void WasapiLoopbackCapturer::ConvertFloatToInt16(const float* src,
                                                  int16_t* dst,
                                                  size_t sample_count) {
  for (size_t i = 0; i < sample_count; ++i) {
    float v = src[i];
    if (v > 1.0f) v = 1.0f;
    if (v < -1.0f) v = -1.0f;
    dst[i] = static_cast<int16_t>(v * 32767.0f);
  }
}

void WasapiLoopbackCapturer::CaptureLoop() {
  EnsureComInit();

  // Thread'i MMCSS "Pro Audio" sınıfına bağla — düzgün audio için kritik.
  // Discord da benzer bir şey yapar. Bu olmadan capture takılır.
  DWORD task_index = 0;
  HANDLE mmcss = ::AvSetMmThreadCharacteristicsW(L"Pro Audio", &task_index);
  if (mmcss) {
    ::AvSetMmThreadPriority(mmcss, AVRT_PRIORITY_CRITICAL);
    WasapiLog("[WASAPI] MMCSS Pro Audio bağlandı");
  } else {
    WasapiLog("[WASAPI] MMCSS bağlanamadı (devam ediyoruz)");
  }

  const int sample_rate = wave_format_->nSamplesPerSec;
  const int channels = wave_format_->nChannels;
  const int bytes_per_sample = wave_format_->wBitsPerSample / 8;

  // Format float mu int16 mı?
  bool is_float = false;
  if (wave_format_->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
    is_float = true;
  } else if (wave_format_->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
    auto* ext = reinterpret_cast<WAVEFORMATEXTENSIBLE*>(wave_format_);
    is_float =
        IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) != 0;
  }

  // 10 ms'lik frame block boyutu (sample frame sayısı)
  const size_t frames_per_block =
      static_cast<size_t>(sample_rate * kFrameDurationMs / 1000);
  const size_t samples_per_block = frames_per_block * channels;

  // Ring buffer benzeri pattern: vector + cursor (offset) — erase O(n)'den kurtul
  std::vector<int16_t> accumulator;
  accumulator.reserve(samples_per_block * 8);  // 80 ms öneri
  size_t cursor = 0;

  while (running_.load()) {
    UINT32 packet_length = 0;
    HRESULT hr = capture_client_->GetNextPacketSize(&packet_length);
    if (FAILED(hr)) {
      WasapiLog("[WASAPI] GetNextPacketSize failed: 0x%lx", (unsigned long)hr);
      break;
    }

    if (packet_length == 0) {
      // Daha kısa sleep — daha responsive
      ::Sleep(2);
      continue;
    }

    BYTE* data = nullptr;
    UINT32 num_frames = 0;
    DWORD flags = 0;
    hr = capture_client_->GetBuffer(&data, &num_frames, &flags, nullptr,
                                     nullptr);
    if (FAILED(hr)) {
      WasapiLog("[WASAPI] GetBuffer failed: 0x%lx", (unsigned long)hr);
      break;
    }

    if (num_frames > 0) {
      size_t sample_count = static_cast<size_t>(num_frames) * channels;
      size_t prev_size = accumulator.size();
      accumulator.resize(prev_size + sample_count);
      int16_t* dst = accumulator.data() + prev_size;

      if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
        std::fill_n(dst, sample_count, int16_t(0));
      } else if (is_float) {
        ConvertFloatToInt16(reinterpret_cast<const float*>(data), dst,
                             sample_count);
      } else if (bytes_per_sample == 2) {
        std::memcpy(dst, data, sample_count * sizeof(int16_t));
      } else {
        std::fill_n(dst, sample_count, int16_t(0));
      }
    }

    capture_client_->ReleaseBuffer(num_frames);

    // 10 ms tam bloklar varsa callback'e ver (cursor pattern — erase yok)
    while (accumulator.size() - cursor >= samples_per_block && callback_) {
      callback_(accumulator.data() + cursor,
                /* bits_per_sample */ 16, sample_rate,
                static_cast<size_t>(channels), frames_per_block);
      cursor += samples_per_block;
    }

    // Cursor çok ilerlerse, kalanı başa kopyala ve resetle (memmove O(n) ama
    // sadece kalan kadar; periyodik olduğu için amortized O(1))
    if (cursor > samples_per_block * 4) {
      size_t leftover = accumulator.size() - cursor;
      if (leftover > 0) {
        std::memmove(accumulator.data(), accumulator.data() + cursor,
                     leftover * sizeof(int16_t));
      }
      accumulator.resize(leftover);
      cursor = 0;
    }
  }

  if (mmcss) ::AvRevertMmThreadCharacteristics(mmcss);
  WasapiLog("[WASAPI] Capture loop bitti");
}

}  // namespace flutter_webrtc_plugin

#endif  // _WIN32
