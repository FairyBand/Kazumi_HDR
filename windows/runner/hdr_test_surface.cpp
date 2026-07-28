#include "hdr_test_surface.h"

#include <algorithm>
#include <array>
#include <sstream>

#include <windows.h>

namespace {

void LogFailure(const char* operation, HRESULT result) {
  std::ostringstream message;
  message << "Kazumi HDR DComp test: " << operation << " failed (0x"
          << std::hex << result << ")\n";
  OutputDebugStringA(message.str().c_str());
}

}  // namespace

HdrTestSurface::HdrTestSurface() = default;

HdrTestSurface::~HdrTestSurface() {
  Detach();
}

bool HdrTestSurface::Initialize(flutter::FlutterEngine* engine,
                                uint32_t width,
                                uint32_t height) {
  if (!engine || width == 0 || height == 0) {
    return false;
  }

  FlutterDesktopPluginRegistrarRef registrar =
      engine->GetRegistrarForPlugin("KazumiHdrDcompTest");
  view_ = FlutterDesktopPluginRegistrarGetView(registrar);
  if (!view_) {
    OutputDebugStringA("Kazumi HDR DComp test: no implicit Flutter view\n");
    return false;
  }

  Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
  if (!engine->GetGraphicsAdapter(&adapter)) {
    OutputDebugStringA("Kazumi HDR DComp test: no Flutter DXGI adapter\n");
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
      adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
      D3D11_CREATE_DEVICE_BGRA_SUPPORT, feature_levels.data(),
      static_cast<UINT>(feature_levels.size()), D3D11_SDK_VERSION, &device_,
      &selected_level, &context_);
  if (FAILED(result)) {
    LogFailure("D3D11CreateDevice", result);
    return false;
  }

  return CreateSwapChain(width, height) && RenderPattern() &&
         Attach(width, height);
}

bool HdrTestSurface::CreateSwapChain(uint32_t width, uint32_t height) {
  Microsoft::WRL::ComPtr<IDXGIDevice> dxgi_device;
  HRESULT result = device_.As(&dxgi_device);
  if (FAILED(result)) {
    LogFailure("ID3D11Device::QueryInterface(IDXGIDevice)", result);
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
    LogFailure("IDXGIAdapter::GetParent(IDXGIFactory2)", result);
    return false;
  }

  DXGI_SWAP_CHAIN_DESC1 description = {};
  description.Width = width;
  description.Height = height;
  description.Format = DXGI_FORMAT_R10G10B10A2_UNORM;
  description.SampleDesc.Count = 1;
  description.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
  description.BufferCount = 2;
  description.Scaling = DXGI_SCALING_STRETCH;
  description.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
  description.AlphaMode = DXGI_ALPHA_MODE_IGNORE;

  result = factory->CreateSwapChainForComposition(
      device_.Get(), &description, nullptr, &swap_chain_);
  if (FAILED(result)) {
    LogFailure("IDXGIFactory2::CreateSwapChainForComposition", result);
    return false;
  }

  Microsoft::WRL::ComPtr<IDXGISwapChain3> swap_chain3;
  result = swap_chain_.As(&swap_chain3);
  if (FAILED(result)) {
    LogFailure("IDXGISwapChain1::QueryInterface(IDXGISwapChain3)", result);
    return false;
  }

  constexpr DXGI_COLOR_SPACE_TYPE color_space =
      DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020;
  UINT support = 0;
  result = swap_chain3->CheckColorSpaceSupport(color_space, &support);
  if (FAILED(result) ||
      (support & DXGI_SWAP_CHAIN_COLOR_SPACE_SUPPORT_FLAG_PRESENT) == 0) {
    LogFailure("IDXGISwapChain3::CheckColorSpaceSupport(PQ/BT.2020)", result);
    return false;
  }
  result = swap_chain3->SetColorSpace1(color_space);
  if (FAILED(result)) {
    LogFailure("IDXGISwapChain3::SetColorSpace1(PQ/BT.2020)", result);
    return false;
  }

  // Static HDR10 metadata for a 1000-nit diagnostic pattern.
  Microsoft::WRL::ComPtr<IDXGISwapChain4> swap_chain4;
  if (SUCCEEDED(swap_chain_.As(&swap_chain4))) {
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

  width_ = width;
  height_ = height;
  return true;
}

bool HdrTestSurface::RenderPattern() {
  Microsoft::WRL::ComPtr<ID3D11Texture2D> buffer;
  HRESULT result = swap_chain_->GetBuffer(0, IID_PPV_ARGS(&buffer));
  if (FAILED(result)) {
    LogFailure("IDXGISwapChain1::GetBuffer", result);
    return false;
  }

  Microsoft::WRL::ComPtr<ID3D11RenderTargetView> target;
  result = device_->CreateRenderTargetView(buffer.Get(), nullptr, &target);
  if (FAILED(result)) {
    LogFailure("ID3D11Device::CreateRenderTargetView", result);
    return false;
  }

  // Values are PQ code values written directly into the 10-bit UNORM buffer.
  const float background[4] = {0.03f, 0.03f, 0.03f, 1.0f};
  context_->ClearRenderTargetView(target.Get(), background);

  Microsoft::WRL::ComPtr<ID3D11DeviceContext1> context1;
  if (SUCCEEDED(context_.As(&context1))) {
    const LONG half_width = static_cast<LONG>(width_ / 2);
    const LONG half_height = static_cast<LONG>(height_ / 2);
    const D3D11_RECT rectangles[] = {
        {0, 0, half_width, half_height},
        {half_width, 0, static_cast<LONG>(width_), half_height},
        {0, half_height, half_width, static_cast<LONG>(height_)},
        {half_width, half_height, static_cast<LONG>(width_),
         static_cast<LONG>(height_)},
    };
    const float colors[][4] = {
        {0.75f, 0.0f, 0.0f, 1.0f},
        {0.0f, 0.75f, 0.0f, 1.0f},
        {0.0f, 0.0f, 0.75f, 1.0f},
        {0.58f, 0.58f, 0.58f, 1.0f},
    };
    for (size_t i = 0; i < std::size(rectangles); ++i) {
      context1->ClearView(target.Get(), colors[i], &rectangles[i], 1);
    }
  }

  result = swap_chain_->Present(1, 0);
  if (FAILED(result)) {
    LogFailure("IDXGISwapChain1::Present", result);
    return false;
  }
  return true;
}

bool HdrTestSurface::Attach(uint32_t width, uint32_t height) {
  if (!view_ || !swap_chain_) {
    return false;
  }
  return FlutterDesktopViewSetHdrCompositionLayer(
      view_, swap_chain_.Get(), 0, 0, width, height, true);
}

void HdrTestSurface::Detach() {
  if (view_) {
    FlutterDesktopViewClearHdrCompositionLayer(view_);
  }
}

bool HdrTestSurface::Resize(uint32_t width, uint32_t height) {
  if (!swap_chain_ || width == 0 || height == 0 ||
      (width == width_ && height == height_)) {
    return true;
  }

  Detach();
  context_->ClearState();
  context_->Flush();
  HRESULT result = swap_chain_->ResizeBuffers(
      0, width, height, DXGI_FORMAT_UNKNOWN, 0);
  if (FAILED(result)) {
    LogFailure("IDXGISwapChain1::ResizeBuffers", result);
    return false;
  }
  width_ = width;
  height_ = height;
  return RenderPattern() && Attach(width, height);
}
