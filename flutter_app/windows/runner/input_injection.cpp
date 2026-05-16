#include "input_injection.h"
#include <sstream>
#include <cmath>

namespace input_injection {

int GetJsonInt(const std::string& json, const std::string& key, int defaultVal) {
  // "key":123 veya "key":-123 formatını ara
  std::string searchKey = "\"" + key + "\"";
  size_t pos = json.find(searchKey);
  if (pos == std::string::npos) return defaultVal;
  pos += searchKey.length();
  // Boşluk ve : atla
  while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t' || json[pos] == ':')) {
    pos++;
  }
  if (pos >= json.size()) return defaultVal;
  // Sayıyı parse et
  int sign = 1;
  if (json[pos] == '-') { sign = -1; pos++; }
  int val = 0;
  bool found = false;
  while (pos < json.size() && json[pos] >= '0' && json[pos] <= '9') {
    val = val * 10 + (json[pos] - '0');
    pos++;
    found = true;
  }
  return found ? val * sign : defaultVal;
}

std::string GetJsonString(const std::string& json, const std::string& key, const std::string& defaultVal) {
  std::string searchKey = "\"" + key + "\"";
  size_t pos = json.find(searchKey);
  if (pos == std::string::npos) return defaultVal;
  pos += searchKey.length();
  while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t' || json[pos] == ':')) {
    pos++;
  }
  if (pos >= json.size() || json[pos] != '"') return defaultVal;
  pos++; // açılış tırnağı atla
  size_t end = json.find('"', pos);
  if (end == std::string::npos) return defaultVal;
  return json.substr(pos, end - pos);
}

void SendMouseEvent(DWORD flags, LONG x, LONG y, DWORD data) {
  INPUT input = {};
  input.type = INPUT_MOUSE;
  input.mi.dwFlags = flags;
  input.mi.dx = x;
  input.mi.dy = y;
  input.mi.mouseData = data;
  input.mi.time = 0;
  input.mi.dwExtraInfo = 0;
  ::SendInput(1, &input, sizeof(INPUT));
}

void SendKeyboardEvent(WORD vkCode, DWORD flags) {
  INPUT input = {};
  input.type = INPUT_KEYBOARD;
  input.ki.wVk = vkCode;
  input.ki.wScan = static_cast<WORD>(::MapVirtualKey(vkCode, MAPVK_VK_TO_VSC));
  input.ki.dwFlags = flags;
  input.ki.time = 0;
  input.ki.dwExtraInfo = 0;
  ::SendInput(1, &input, sizeof(INPUT));
}

// Virtual key code mapping — common keys
WORD KeyCodeToVK(int keyCode) {
  // ASCII / keyCode mapping
  if (keyCode >= 65 && keyCode <= 90) return static_cast<WORD>(keyCode); // A-Z
  if (keyCode >= 48 && keyCode <= 57) return static_cast<WORD>(keyCode); // 0-9
  if (keyCode >= 112 && keyCode <= 123) return static_cast<WORD>(keyCode); // F1-F12
  switch (keyCode) {
    case 8:   return VK_BACK;
    case 9:   return VK_TAB;
    case 13:  return VK_RETURN;
    case 16:  return VK_SHIFT;
    case 17:  return VK_CONTROL;
    case 18:  return VK_MENU; // Alt
    case 20:  return VK_CAPITAL;
    case 27:  return VK_ESCAPE;
    case 32:  return VK_SPACE;
    case 33:  return VK_PRIOR; // PageUp
    case 34:  return VK_NEXT;  // PageDown
    case 35:  return VK_END;
    case 36:  return VK_HOME;
    case 37:  return VK_LEFT;
    case 38:  return VK_UP;
    case 39:  return VK_RIGHT;
    case 40:  return VK_DOWN;
    case 45:  return VK_INSERT;
    case 46:  return VK_DELETE;
    case 186: return VK_OEM_1; // ;:
    case 187: return VK_OEM_PLUS; // =+
    case 188: return VK_OEM_COMMA; // ,<
    case 189: return VK_OEM_MINUS; // -_
    case 190: return VK_OEM_PERIOD; // .>
    case 191: return VK_OEM_2; // /?
    case 192: return VK_OEM_3; // `~
    case 219: return VK_OEM_4; // [{
    case 220: return VK_OEM_5; // \|
    case 221: return VK_OEM_6; // ]}
    case 222: return VK_OEM_7; // '"
    case 116: return VK_F5;
    default:  return 0;
  }
}

void HandleInputEvent(const std::string& jsonEvent) {
  std::string type = GetJsonString(jsonEvent, "type");

  if (type == "mouse_move") {
    int x = GetJsonInt(jsonEvent, "x");
    int y = GetJsonInt(jsonEvent, "y");
    // Absolute coordinates: 0-65535 aralığı
    LONG ax = static_cast<LONG>((x * 65535) / GetSystemMetrics(SM_CXSCREEN));
    LONG ay = static_cast<LONG>((y * 65535) / GetSystemMetrics(SM_CYSCREEN));
    SendMouseEvent(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE, ax, ay);
  }
  else if (type == "mouse_down") {
    int x = GetJsonInt(jsonEvent, "x");
    int y = GetJsonInt(jsonEvent, "y");
    int button = GetJsonInt(jsonEvent, "button", 0);
    LONG ax = static_cast<LONG>((x * 65535) / GetSystemMetrics(SM_CXSCREEN));
    LONG ay = static_cast<LONG>((y * 65535) / GetSystemMetrics(SM_CYSCREEN));
    SendMouseEvent(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE, ax, ay);
    DWORD downFlag;
    switch (button) {
      case 1:  downFlag = MOUSEEVENTF_RIGHTDOWN; break;
      case 2:  downFlag = MOUSEEVENTF_MIDDLEDOWN; break;
      default: downFlag = MOUSEEVENTF_LEFTDOWN; break;
    }
    SendMouseEvent(downFlag);
  }
  else if (type == "mouse_up") {
    int button = GetJsonInt(jsonEvent, "button", 0);
    DWORD upFlag;
    switch (button) {
      case 1:  upFlag = MOUSEEVENTF_RIGHTUP; break;
      case 2:  upFlag = MOUSEEVENTF_MIDDLEUP; break;
      default: upFlag = MOUSEEVENTF_LEFTUP; break;
    }
    SendMouseEvent(upFlag);
  }
  else if (type == "mouse_wheel") {
    int delta = GetJsonInt(jsonEvent, "delta", 0);
    SendMouseEvent(MOUSEEVENTF_WHEEL, 0, 0, static_cast<DWORD>(delta));
  }
  else if (type == "key_down") {
    int keyCode = GetJsonInt(jsonEvent, "keyCode", 0);
    WORD vk = KeyCodeToVK(keyCode);
    if (vk != 0) {
      SendKeyboardEvent(vk, 0);
    }
  }
  else if (type == "key_up") {
    int keyCode = GetJsonInt(jsonEvent, "keyCode", 0);
    WORD vk = KeyCodeToVK(keyCode);
    if (vk != 0) {
      SendKeyboardEvent(vk, KEYEVENTF_KEYUP);
    }
  }
}

}  // namespace input_injection
