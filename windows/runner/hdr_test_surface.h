#ifndef RUNNER_HDR_TEST_SURFACE_H_
#define RUNNER_HDR_TEST_SURFACE_H_

#include <flutter/flutter_engine.h>
#include <flutter_windows.h>

#include <cstdint>

#include <d3d11_1.h>
#include <dxgi1_6.h>
#include <wrl/client.h>

// A diagnostic 10-bit PQ composition swap chain. This is enabled only when
// KAZUMI_HDR_DCOMP_TEST=1 and is used to validate the custom engine's single
// HWND DirectComposition path before wiring the same path to mpv.
class HdrTestSurface {
 public:
  HdrTestSurface();
  ~HdrTestSurface();

  HdrTestSurface(const HdrTestSurface&) = delete;
  HdrTestSurface& operator=(const HdrTestSurface&) = delete;

  bool Initialize(flutter::FlutterEngine* engine,
                  uint32_t width,
                  uint32_t height);
  bool Resize(uint32_t width, uint32_t height);

 private:
  bool CreateSwapChain(uint32_t width, uint32_t height);
  bool RenderPattern();
  bool Attach(uint32_t width, uint32_t height);
  void Detach();

  FlutterDesktopViewRef view_ = nullptr;
  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
  Microsoft::WRL::ComPtr<IDXGISwapChain1> swap_chain_;
  uint32_t width_ = 0;
  uint32_t height_ = 0;
};

#endif  // RUNNER_HDR_TEST_SURFACE_H_
