cmake_minimum_required(VERSION 3.14)
project(tunnel_native LANGUAGES NONE)

# Discord Clone — Cloudflare Tunnel binary'sini build çıktısına kopyalar.
# Eski Wintun-tabanlı sanal ağ özelliği kaldırıldı; tüm reachability
# Cloudflare Tunnel (TryCloudflare) üzerinden HTTPS ile sağlanıyor.

# Runner exe'nin output dizini — TARGET_FILE_DIR generator expression circular
# dep'e neden olur, bu yüzden standart Flutter layout kullanıyoruz.
set(RUNNER_OUTPUT_DIR "${CMAKE_BINARY_DIR}/runner/$<CONFIG>")
set(CLOUDFLARED_EXE "${CMAKE_CURRENT_SOURCE_DIR}/cloudflared/cloudflared.exe")

# Custom target — build sırasında cloudflared.exe'yi runner output'una kopyala
add_custom_target(copy_cloudflared ALL
  COMMAND ${CMAKE_COMMAND} -E make_directory "${RUNNER_OUTPUT_DIR}"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CLOUDFLARED_EXE}"
    "${RUNNER_OUTPUT_DIR}/cloudflared.exe"
  COMMENT "cloudflared.exe runner output'una kopyalanıyor"
)

# Install rule'u parent CMakeLists.txt'de — INSTALL_BUNDLE_LIB_DIR önce tanımlansın.
