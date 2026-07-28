#ifndef HDR_DCOMP_RENDERER_H_
#define HDR_DCOMP_RENDERER_H_

#include <Windows.h>
#include <d3d11.h>
#include <dxgi1_6.h>
#include <wrl.h>

#include <cstdint>
#include <unordered_map>

#include "d3d11_renderer.h"

// Owns the real 10-bit PQ composition swap chain used by libmpv's DXGI render
// API. The swap chain is attached to Flutter's DirectComposition visual tree
// by the custom FlutterDesktopViewSetHdrCompositionLayer API.
class HdrDcompRenderer {
 public:
  HdrDcompRenderer(int32_t width,
                   int32_t height,
                   IDXGIAdapter* flutter_adapter);
  ~HdrDcompRenderer();

  HdrDcompRenderer(const HdrDcompRenderer&) = delete;
  HdrDcompRenderer& operator=(const HdrDcompRenderer&) = delete;

  ID3D11Device* device() const { return mpv_renderer_->device(); }
  IDXGISwapChain* mpv_swap_chain() const {
    return mpv_renderer_->swap_chain();
  }
  IDXGISwapChain1* composition_swap_chain() const {
    return composition_swap_chain_.Get();
  }
  int32_t width() const { return width_; }
  int32_t height() const { return height_; }

  bool Resize(int32_t width, int32_t height);
  bool Present();

 private:
  bool CreateDevice(IDXGIAdapter* flutter_adapter);
  bool CreateSwapChain();
  bool ConfigureHdr();
  bool WaitForGpuIdle(DWORD timeout_ms = 500);

  int32_t width_ = 1;
  int32_t height_ = 1;
  Microsoft::WRL::ComPtr<ID3D11Device> composition_device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> composition_context_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext4> composition_context4_;
  Microsoft::WRL::ComPtr<ID3D11Fence> composition_fence_;
  uint64_t composition_fence_value_ = 0;
  HANDLE composition_fence_event_ = nullptr;
  std::unique_ptr<D3D11Renderer> mpv_renderer_;
  Microsoft::WRL::ComPtr<IDXGISwapChain1> composition_swap_chain_;
  std::unordered_map<void*, Microsoft::WRL::ComPtr<ID3D11Texture2D>>
      consumer_textures_;
};

#endif  // HDR_DCOMP_RENDERER_H_
