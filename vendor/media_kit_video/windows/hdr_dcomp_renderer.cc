#include "hdr_dcomp_renderer.h"

#include <algorithm>
#include <array>
#include <iostream>
#include <stdexcept>

namespace {

void LogFailure(const char* operation, HRESULT result) {
  std::cout << "media_kit: HdrDcompRenderer: " << operation
            << " failed (hr=0x" << std::hex << result << std::dec << ")"
            << std::endl;
}

}  // namespace

HdrDcompRenderer::HdrDcompRenderer(int32_t width,
                                   int32_t height,
                                   IDXGIAdapter* flutter_adapter)
    : width_(std::max(width, 1)), height_(std::max(height, 1)) {
  if (!CreateDevice(flutter_adapter) || !CreateSwapChain()) {
    throw std::runtime_error("Unable to create HDR composition swap chain.");
  }
}

HdrDcompRenderer::~HdrDcompRenderer() {
  WaitForGpuIdle();
  consumer_textures_.clear();
  if (composition_fence_event_) {
    ::CloseHandle(composition_fence_event_);
    composition_fence_event_ = nullptr;
  }
}

bool HdrDcompRenderer::CreateDevice(IDXGIAdapter* flutter_adapter) {
  if (!flutter_adapter) {
    std::cout << "media_kit: HdrDcompRenderer: Flutter adapter unavailable."
              << std::endl;
    return false;
  }
  constexpr std::array<D3D_FEATURE_LEVEL, 4> feature_levels = {
      D3D_FEATURE_LEVEL_11_1,
      D3D_FEATURE_LEVEL_11_0,
      D3D_FEATURE_LEVEL_10_1,
      D3D_FEATURE_LEVEL_10_0,
  };
  D3D_FEATURE_LEVEL selected_level;
  HRESULT result = D3D11CreateDevice(
      flutter_adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr,
      D3D11_CREATE_DEVICE_BGRA_SUPPORT, feature_levels.data(),
      static_cast<UINT>(feature_levels.size()), D3D11_SDK_VERSION,
      &composition_device_, &selected_level, &composition_context_);
  if (FAILED(result)) {
    LogFailure("D3D11CreateDevice(composition)", result);
    return false;
  }
  result = composition_context_.As(&composition_context4_);
  if (FAILED(result)) {
    LogFailure("QueryInterface(ID3D11DeviceContext4)", result);
    return false;
  }
  Microsoft::WRL::ComPtr<ID3D11Device5> device5;
  result = composition_device_.As(&device5);
  if (FAILED(result)) {
    LogFailure("QueryInterface(ID3D11Device5)", result);
    return false;
  }
  result = device5->CreateFence(0, D3D11_FENCE_FLAG_NONE,
                                IID_PPV_ARGS(&composition_fence_));
  if (FAILED(result)) {
    LogFailure("CreateFence(composition)", result);
    return false;
  }
  composition_fence_event_ = ::CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (!composition_fence_event_) {
    LogFailure("CreateEvent(composition fence)",
               HRESULT_FROM_WIN32(GetLastError()));
    return false;
  }
  mpv_renderer_ = std::make_unique<D3D11Renderer>(
      width_, height_, flutter_adapter, DXGI_FORMAT_R10G10B10A2_UNORM);
  return true;
}

bool HdrDcompRenderer::CreateSwapChain() {
  Microsoft::WRL::ComPtr<IDXGIDevice> dxgi_device;
  HRESULT result = composition_device_.As(&dxgi_device);
  if (FAILED(result)) {
    LogFailure("QueryInterface(IDXGIDevice)", result);
    return false;
  }
  Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
  result = dxgi_device->GetAdapter(&adapter);
  if (FAILED(result)) {
    LogFailure("IDXGIDevice::GetAdapter", result);
    return false;
  }
  Microsoft::WRL::ComPtr<IDXGIFactory2> factory;
  result = adapter->GetParent(IID_PPV_ARGS(&factory));
  if (FAILED(result)) {
    LogFailure("IDXGIAdapter::GetParent", result);
    return false;
  }

  DXGI_SWAP_CHAIN_DESC1 description = {};
  description.Width = static_cast<UINT>(width_);
  description.Height = static_cast<UINT>(height_);
  description.Format = DXGI_FORMAT_R10G10B10A2_UNORM;
  description.SampleDesc.Count = 1;
  // Match mpv's native D3D11 swapchain requirements. gpu-next may sample the
  // target and uses an unordered-access view for non-BGRA output formats.
  // Supplying only RENDER_TARGET_OUTPUT lets the DXGI render API initialize,
  // but its render passes leave the R10 target at the opaque-black clear value.
  description.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT |
                            DXGI_USAGE_SHADER_INPUT |
                            DXGI_USAGE_UNORDERED_ACCESS;
  description.BufferCount = 2;
  description.Scaling = DXGI_SCALING_STRETCH;
  description.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
  description.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
  result = factory->CreateSwapChainForComposition(
      composition_device_.Get(), &description, nullptr,
      &composition_swap_chain_);
  if (FAILED(result)) {
    LogFailure("CreateSwapChainForComposition", result);
    return false;
  }
  return ConfigureHdr();
}

bool HdrDcompRenderer::ConfigureHdr() {
  Microsoft::WRL::ComPtr<IDXGISwapChain3> swap_chain3;
  HRESULT result = composition_swap_chain_.As(&swap_chain3);
  if (FAILED(result)) {
    LogFailure("QueryInterface(IDXGISwapChain3)", result);
    return false;
  }
  constexpr auto color_space = DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020;
  UINT support = 0;
  result = swap_chain3->CheckColorSpaceSupport(color_space, &support);
  if (FAILED(result) ||
      (support & DXGI_SWAP_CHAIN_COLOR_SPACE_SUPPORT_FLAG_PRESENT) == 0) {
    LogFailure("CheckColorSpaceSupport(PQ/BT.2020)", result);
    return false;
  }
  result = swap_chain3->SetColorSpace1(color_space);
  if (FAILED(result)) {
    LogFailure("SetColorSpace1(PQ/BT.2020)", result);
    return false;
  }

  Microsoft::WRL::ComPtr<IDXGISwapChain4> swap_chain4;
  if (SUCCEEDED(composition_swap_chain_.As(&swap_chain4))) {
    DXGI_HDR_METADATA_HDR10 metadata = {};
    metadata.RedPrimary[0] = 35400;
    metadata.RedPrimary[1] = 14600;
    metadata.GreenPrimary[0] = 8500;
    metadata.GreenPrimary[1] = 39850;
    metadata.BluePrimary[0] = 6550;
    metadata.BluePrimary[1] = 2300;
    metadata.WhitePoint[0] = 15635;
    metadata.WhitePoint[1] = 16450;
    metadata.MaxMasteringLuminance = 1000 * 10000;
    metadata.MinMasteringLuminance = 1;
    metadata.MaxContentLightLevel = 1000;
    metadata.MaxFrameAverageLightLevel = 400;
    swap_chain4->SetHDRMetaData(DXGI_HDR_METADATA_TYPE_HDR10,
                                sizeof(metadata), &metadata);
  }
  return true;
}

bool HdrDcompRenderer::Resize(int32_t width, int32_t height) {
  width = std::max(width, 1);
  height = std::max(height, 1);
  if (width == width_ && height == height_) {
    return true;
  }
  if (!WaitForGpuIdle()) {
    return false;
  }
  // The consumer textures keep the producer's legacy shared resources alive.
  // Release them only after the last CopyResource has completed, before the
  // producer recreates its mailbox slots.
  consumer_textures_.clear();
  composition_context_->ClearState();
  composition_context_->Flush();
  HRESULT result = composition_swap_chain_->ResizeBuffers(
      0, static_cast<UINT>(width), static_cast<UINT>(height),
      DXGI_FORMAT_UNKNOWN, 0);
  if (FAILED(result)) {
    LogFailure("ResizeBuffers", result);
    return false;
  }
  if (!mpv_renderer_->SetSize(width, height)) {
    return false;
  }
  width_ = width;
  height_ = height;
  return ConfigureHdr();
}

bool HdrDcompRenderer::Present() {
  mpv_renderer_->ProducerCommit();
  Microsoft::WRL::ComPtr<ID3D11Texture2D> back_buffer;
  HRESULT result = composition_swap_chain_->GetBuffer(
      0, IID_PPV_ARGS(&back_buffer));
  if (FAILED(result)) {
    LogFailure("GetBuffer(composition)", result);
    return false;
  }
  const HANDLE completed_handle = mpv_renderer_->ConsumerAcquire();
  if (!completed_handle) {
    return false;
  }
  auto found = consumer_textures_.find(completed_handle);
  if (found == consumer_textures_.end()) {
    Microsoft::WRL::ComPtr<ID3D11Texture2D> completed_frame;
    result = composition_device_->OpenSharedResource(
        completed_handle, IID_PPV_ARGS(&completed_frame));
    if (FAILED(result)) {
      LogFailure("OpenSharedResource(completed HDR frame)", result);
      return false;
    }
    found = consumer_textures_
                .emplace(completed_handle, std::move(completed_frame))
                .first;
  }
  composition_context_->CopyResource(back_buffer.Get(), found->second.Get());
  // Never stall the media worker behind the compositor. If the flip queue is
  // full, keeping the previous frame is preferable to starving Flutter's UI.
  result = composition_swap_chain_->Present(0, DXGI_PRESENT_DO_NOT_WAIT);
  if (result == DXGI_ERROR_WAS_STILL_DRAWING) {
    return true;
  }
  if (FAILED(result)) {
    LogFailure("Present", result);
    return false;
  }
  return true;
}

bool HdrDcompRenderer::WaitForGpuIdle(DWORD timeout_ms) {
  if (!composition_context4_ || !composition_fence_ ||
      !composition_fence_event_) {
    return false;
  }
  const uint64_t value = ++composition_fence_value_;
  HRESULT result =
      composition_context4_->Signal(composition_fence_.Get(), value);
  if (FAILED(result)) {
    LogFailure("Signal(composition fence)", result);
    return false;
  }
  result = composition_fence_->SetEventOnCompletion(
      value, composition_fence_event_);
  if (FAILED(result)) {
    LogFailure("SetEventOnCompletion(composition fence)", result);
    return false;
  }
  composition_context_->Flush();
  const DWORD wait_result =
      ::WaitForSingleObject(composition_fence_event_, timeout_ms);
  if (wait_result != WAIT_OBJECT_0) {
    const HRESULT wait_failure = wait_result == WAIT_TIMEOUT
                                     ? DXGI_ERROR_WAS_STILL_DRAWING
                                     : HRESULT_FROM_WIN32(GetLastError());
    LogFailure("WaitForSingleObject(composition fence)", wait_failure);
    return false;
  }
  return true;
}
