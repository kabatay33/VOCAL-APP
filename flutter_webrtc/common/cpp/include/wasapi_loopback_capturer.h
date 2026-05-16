#ifndef WASAPI_LOOPBACK_CAPTURER_H
#define WASAPI_LOOPBACK_CAPTURER_H

#ifdef _WIN32

#include <Audioclient.h>
#include <mmdeviceapi.h>

#include <atomic>
#include <future>
#include <functional>
#include <string>
#include <thread>
#include <vector>

namespace flutter_webrtc_plugin {

/// Debug log helper — dosyaya + stderr'a yazar, hem flush yapar.
/// Release build'de stdout buffering nedeniyle std::cout görünmüyor;
/// bu sorunu çözmek için printf-stili kullanılır.
void WasapiLog(const char* fmt, ...);

/// Windows Core Audio (WASAPI) Loopback Capture.
///
/// Sistem'in varsayılan render endpoint'inden (yani hoparlöre giden ses)
/// loopback modunda PCM frame'leri yakalar. Yakalanan ses anlık olarak
/// callback ile dışarı verilir; çağıran taraf bunu istediği audio source'a
/// (örn. libwebrtc kCustom RTCAudioSource) feed edebilir.
///
/// Output format: 16-bit signed PCM, sample rate ve channel count
/// callback parametrelerinde belirtilir (genelde 48000 Hz, 2 channel).
class WasapiLoopbackCapturer {
 public:
  using FrameCallback = std::function<void(const void* data,
                                            int bits_per_sample,
                                            int sample_rate,
                                            size_t channels,
                                            size_t frames)>;

  WasapiLoopbackCapturer();
  ~WasapiLoopbackCapturer();

  // Kopyalama yok
  WasapiLoopbackCapturer(const WasapiLoopbackCapturer&) = delete;
  WasapiLoopbackCapturer& operator=(const WasapiLoopbackCapturer&) = delete;

  /// Yakalamayı başlatır. Başarılıysa true döner.
  /// callback worker thread'den çağrılır; thread-safe olmalı.
  bool Start(FrameCallback callback);

  /// Yakalamayı durdurur ve worker thread'i bekler.
  void Stop();

  bool IsRunning() const { return running_.load(); }

  /// Son başarısız Start için açıklayıcı hata mesajı.
  const std::string& LastError() const { return last_error_; }

 private:
  /// Worker thread içinden çağrılır — MTA apartment'ta WASAPI init.
  bool InitOnWorker();
  void CaptureLoop();
  void Cleanup();
  // Float (IEEE) yakalandığında int16'ya dönüştürme yardımcısı
  static void ConvertFloatToInt16(const float* src,
                                  int16_t* dst,
                                  size_t sample_count);

  IMMDeviceEnumerator* enumerator_ = nullptr;
  IMMDevice* device_ = nullptr;
  IAudioClient* audio_client_ = nullptr;
  IAudioCaptureClient* capture_client_ = nullptr;
  WAVEFORMATEX* wave_format_ = nullptr;

  std::atomic<bool> running_{false};
  std::thread thread_;
  FrameCallback callback_;
  std::vector<int16_t> conversion_buffer_;
  std::string last_error_;
};

}  // namespace flutter_webrtc_plugin

#endif  // _WIN32

#endif  // WASAPI_LOOPBACK_CAPTURER_H
