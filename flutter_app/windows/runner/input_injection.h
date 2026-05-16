#ifndef RUNNER_INPUT_INJECTION_H_
#define RUNNER_INPUT_INJECTION_H_

#include <windows.h>
#include <string>

// JSON parse için basit bir yaklaşım — tam JSON parser yerine
// basit string manipülasyonu kullanıyoruz (event'ler küçük ve basit).

namespace input_injection {

// JSON string içinden "key":value çiftini bulur (sayısal değerler için)
int GetJsonInt(const std::string& json, const std::string& key, int defaultVal = 0);
// JSON string içinden "key":"value" çiftini bulur (string değerler için)
std::string GetJsonString(const std::string& json, const std::string& key, const std::string& defaultVal = "");

// Mouse event'i uygula
void SendMouseEvent(DWORD flags, LONG x = 0, LONG y = 0, DWORD data = 0);
// Klavye event'i uygula
void SendKeyboardEvent(WORD vkCode, DWORD flags);

// Gelen JSON event'ini parse et ve uygula
void HandleInputEvent(const std::string& jsonEvent);

}  // namespace input_injection

#endif  // RUNNER_INPUT_INJECTION_H_
