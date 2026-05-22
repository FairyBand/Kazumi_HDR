// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "video_output.h"

#include <algorithm>
#include <string>

// Limit the frame size to 1080p in software rendering.
// This is for performance reasons & to avoid allocating too much memory.
#define SW_RENDERING_MAX_WIDTH 1920
#define SW_RENDERING_MAX_HEIGHT 1080
#define SW_RENDERING_PIXEL_BUFFER_SIZE \
  (SW_RENDERING_MAX_WIDTH) * (SW_RENDERING_MAX_HEIGHT) * (4)

VideoOutput::VideoOutput(int64_t handle,
                         VideoOutputConfiguration configuration,
                         flutter::PluginRegistrarWindows* registrar,
                         ThreadPool* thread_pool_ref,
                         std::function<void(std::function<void()>)>
                             run_on_main_thread)
    : handle_(reinterpret_cast<mpv_handle*>(handle)),
      width_(configuration.width),
      height_(configuration.height),
      configuration_(configuration),
      registrar_(registrar),
      thread_pool_ref_(thread_pool_ref),
      run_on_main_thread_(run_on_main_thread) {
  // The constructor must be invoked through the thread pool.
  auto future = thread_pool_ref_->Post([&]() {
    mpv_set_option_string(handle_, "video-sync", "audio");
    mpv_set_option_string(handle_, "video-timing-offset", "0");

    if (configuration.windows_native_window) {
      CreateNativeWindow();
      CreatePlaceholderTexture();
      return;
    }
    
    // Initialize video playback with hardware acceleration using native D3D11.
    auto is_hardware_acceleration_enabled = false;
    
    if (configuration.enable_hardware_acceleration) {
      try {
        IDXGIAdapter* flutter_adapter = nullptr;
        if (auto* view = registrar_->GetView()) {
          flutter_adapter = view->GetGraphicsAdapter();
        }
        d3d11_renderer_ = std::make_unique<D3D11Renderer>(
            static_cast<int32_t>(width_.value_or(1)),
            static_cast<int32_t>(height_.value_or(1)),
            flutter_adapter);
        
        // Initialize mpv with the D3D11 device and swap chain
        mpv_dxgi_init_params init_params = {
            d3d11_renderer_->device(),
            // Must provide swap chain, not nullptr
            // Otherwise, you will get freeze.
            d3d11_renderer_->swap_chain()
        };
        
        mpv_render_param params[] = {
            {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_DXGI},
            {MPV_RENDER_PARAM_DXGI_INIT_PARAMS, &init_params},
            {MPV_RENDER_PARAM_INVALID, nullptr},
        };
        
        // Create render context.
        if (mpv_render_context_create(&render_context_, handle_, params) == 0) {
          mpv_render_context_set_update_callback(
              render_context_,
              [](void* context) {
                auto that = reinterpret_cast<VideoOutput*>(context);
                that->NotifyRender();
              },
              reinterpret_cast<void*>(this));
          
          // Now create the Flutter texture after successful render context creation
          Resize(width_.value_or(1), height_.value_or(1));
          
          // Set flag to true, indicating that H/W rendering is supported.
          is_hardware_acceleration_enabled = true;
          std::cout << "media_kit: VideoOutput: Using native D3D11 H/W rendering."
                    << std::endl;
        } else {
          std::cout << "media_kit: VideoOutput: Failed to create mpv render context."
                    << std::endl;
          d3d11_renderer_.reset(nullptr);
        }
      } catch (const std::exception& e) {
        // Fallback to software rendering.
        std::cout << "media_kit: VideoOutput: Failed to initialize D3D11: " 
                  << e.what() << ", falling back to S/W."
                  << std::endl;
        d3d11_renderer_.reset(nullptr);
      } catch (...) {
        // Fallback to software rendering.
        std::cout << "media_kit: VideoOutput: Failed to initialize D3D11, falling back to S/W."
                  << std::endl;
        d3d11_renderer_.reset(nullptr);
      }
    }
    
    if (!is_hardware_acceleration_enabled) {
      std::cout << "media_kit: VideoOutput: Using S/W rendering." << std::endl;
      // Allocate a "large enough" buffer ahead of time.
      pixel_buffer_ =
          std::make_unique<uint8_t[]>(SW_RENDERING_PIXEL_BUFFER_SIZE);
      Resize(width_.value_or(1), height_.value_or(1));
      mpv_render_param params[] = {
          {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_SW},
          {MPV_RENDER_PARAM_INVALID, nullptr},
      };
      if (mpv_render_context_create(&render_context_, handle_, params) == 0) {
        mpv_render_context_set_update_callback(
            render_context_,
            [](void* context) {
              auto that = reinterpret_cast<VideoOutput*>(context);
              that->NotifyRender();
            },
            reinterpret_cast<void*>(this));
      }
    }
  });
  future.wait();
}

VideoOutput::~VideoOutput() {
  destroyed_ = true;
  if (native_window_) {
    auto promise = std::make_shared<std::promise<void>>();
    run_on_main_thread_([window = native_window_, promise]() {
      ::DestroyWindow(window);
      promise->set_value();
    });
    promise->get_future().wait();
    native_window_ = nullptr;
  }
  if (texture_id_) {
    auto promise = std::make_shared<std::promise<void>>();
    registrar_->texture_registrar()->UnregisterTexture(
        texture_id_, [&, texture_id = texture_id_, promise]() {
          thread_pool_ref_->Post([&, id = texture_id, promise]() {
            std::cout << "media_kit: VideoOutput: Free Texture: " << id
                      << std::endl;
            std::cout << "VideoOutput::~VideoOutput: "
                      << reinterpret_cast<int64_t>(handle_) << std::endl;
            std::lock_guard<std::mutex> lock(textures_mutex_);
            texture_variants_.clear();
            // H/W
            textures_.clear();
            // S/W
            pixel_buffer_textures_.clear();
            // Free D3D11Renderer through the thread pool
            d3d11_renderer_.reset(nullptr);
            promise->set_value();
          });
        });
    promise->get_future().wait();
  }
  texture_id_ = 0;

  thread_pool_ref_->Post([render_context = render_context_]() {
    if (render_context) {
      mpv_render_context_free(render_context);
    }
  });
}

void VideoOutput::CreateNativeWindow() {
  auto promise = std::make_shared<std::promise<void>>();
  run_on_main_thread_([&, promise]() {
    if (auto* view = registrar_->GetView()) {
      flutter_view_window_ = view->GetNativeWindow();
    }
    if (flutter_view_window_) {
      parent_window_ = ::GetAncestor(flutter_view_window_, GA_ROOT);
    }
    if (!parent_window_) {
      parent_window_ = ::GetActiveWindow();
    }

    POINT origin = {0, 0};
    if (parent_window_) {
      ::ClientToScreen(parent_window_, &origin);
    }

    native_window_ = ::CreateWindowExW(
        WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        L"STATIC",
        L"",
        WS_POPUP | WS_VISIBLE | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
        origin.x,
        origin.y,
        static_cast<int>(width_.value_or(1)),
        static_cast<int>(height_.value_or(1)),
        nullptr,
        nullptr,
        ::GetModuleHandleW(nullptr),
        nullptr);
    if (native_window_ && parent_window_) {
      ::SetWindowPos(native_window_, parent_window_, origin.x, origin.y,
                     static_cast<int>(width_.value_or(1)),
                     static_cast<int>(height_.value_or(1)),
                     SWP_NOACTIVATE);
    }
    promise->set_value();
  });
  promise->get_future().wait();

  if (!native_window_) {
    std::cout << "media_kit: VideoOutput: Failed to create native HDR window."
              << std::endl;
    return;
  }

  const auto wid = std::to_string(reinterpret_cast<intptr_t>(native_window_));
  mpv_set_option_string(handle_, "wid", wid.c_str());
  mpv_set_option_string(handle_, "force-window", "yes");
  std::cout << "media_kit: VideoOutput: Using native Windows HWND for mpv: "
            << wid << std::endl;
}

void VideoOutput::CreatePlaceholderTexture() {
  if (pixel_buffer_ == nullptr) {
    pixel_buffer_ = std::make_unique<uint8_t[]>(4);
  }
  pixel_buffer_[0] = 1;
  pixel_buffer_[1] = 2;
  pixel_buffer_[2] = 3;
  pixel_buffer_[3] = 0;

  auto pixel_buffer_texture = std::make_unique<FlutterDesktopPixelBuffer>();
  pixel_buffer_texture->buffer = pixel_buffer_.get();
  pixel_buffer_texture->width = 1;
  pixel_buffer_texture->height = 1;
  pixel_buffer_texture->release_context = nullptr;
  pixel_buffer_texture->release_callback = [](void*) {};

  auto texture_variant = std::make_unique<flutter::TextureVariant>(
      flutter::PixelBufferTexture([&](auto, auto) {
        std::lock_guard<std::mutex> lock(textures_mutex_);
        if (texture_id_) {
          return pixel_buffer_textures_.at(texture_id_).get();
        }
        return (FlutterDesktopPixelBuffer*)nullptr;
      }));

  texture_id_ =
      registrar_->texture_registrar()->RegisterTexture(texture_variant.get());
  {
    std::lock_guard<std::mutex> lock(textures_mutex_);
    pixel_buffer_textures_.emplace(
        std::make_pair(texture_id_, std::move(pixel_buffer_texture)));
    texture_variants_.emplace(
        std::make_pair(texture_id_, std::move(texture_variant)));
  }
}

void VideoOutput::NotifyRender() {
  if (destroyed_) {
    return;
  }
  thread_pool_ref_->Post(std::bind(&VideoOutput::CheckAndResize, this));
  thread_pool_ref_->Post(std::bind(&VideoOutput::Render, this));
}

void VideoOutput::Render() {
  if (texture_id_) {
    // H/W
    if (d3d11_renderer_ != nullptr) {
      mpv_render_context_render(render_context_, nullptr);
      mpv_render_context_report_swap(render_context_);
      d3d11_renderer_->ProducerCommit();
    }
    // S/W
    if (pixel_buffer_ != nullptr) {
      int32_t size[]{
          static_cast<int32_t>(pixel_buffer_textures_.at(texture_id_)->width),
          static_cast<int32_t>(pixel_buffer_textures_.at(texture_id_)->height),
      };
      auto pitch = 4 * size[0];
      mpv_render_param params[]{
          {MPV_RENDER_PARAM_SW_SIZE, size},
          {MPV_RENDER_PARAM_SW_FORMAT, "rgb0"},
          {MPV_RENDER_PARAM_SW_STRIDE, &pitch},
          {MPV_RENDER_PARAM_SW_POINTER, pixel_buffer_.get()},
          {MPV_RENDER_PARAM_INVALID, nullptr},
      };
      mpv_render_context_render(render_context_, params);
    }
    try {
      // Notify Flutter that a new frame is available.
      registrar_->texture_registrar()->MarkTextureFrameAvailable(texture_id_);
    } catch (...) {
      // Prevent any redundant exceptions if the texture is unregistered etc.
    }
  }
}

void VideoOutput::SetTextureUpdateCallback(
    std::function<void(int64_t, int64_t, int64_t)> callback) {
  texture_update_callback_ = callback;
  if (configuration_.windows_native_window) {
    texture_update_callback_(texture_id_, width_.value_or(1),
                             height_.value_or(1));
    return;
  }
  texture_update_callback_(texture_id_, GetVideoWidth(), GetVideoHeight());
}

void VideoOutput::SetSize(std::optional<int64_t> width,
                          std::optional<int64_t> height) {
  if (configuration_.windows_native_window) {
    width_ = width;
    height_ = height;
    return;
  }
  thread_pool_ref_->Post([&, width, height]() {
    if (width.has_value()) {
      // H/W
      if (d3d11_renderer_ != nullptr) {
        width_ = width.value();
      }
      // S/W
      if (pixel_buffer_ != nullptr) {
        // Limit width if software rendering is being used.
        width_ = std::clamp(width.value(), static_cast<int64_t>(0),
                            static_cast<int64_t>(SW_RENDERING_MAX_WIDTH));
      }
    } else {
      width_ = std::nullopt;
    }
    if (height.has_value()) {
      // H/W
      if (d3d11_renderer_ != nullptr) {
        height_ = height.value();
      }
      // S/W
      if (pixel_buffer_ != nullptr) {
        // Limit width if software rendering is being used.
        height_ = std::clamp(height.value(), static_cast<int64_t>(0),
                             static_cast<int64_t>(SW_RENDERING_MAX_HEIGHT));
      }
    } else {
      height_ = std::nullopt;
    }
  });
}

void VideoOutput::SetNativeWindowRect(int64_t left,
                                      int64_t top,
                                      int64_t width,
                                      int64_t height,
                                      int64_t clip_top,
                                      int64_t clip_bottom) {
  if (!configuration_.windows_native_window || !native_window_) {
    return;
  }
  native_window_left_ = left;
  native_window_top_ = top;
  native_window_width_ = width;
  native_window_height_ = height;
  native_window_clip_top_ = clip_top;
  native_window_clip_bottom_ = clip_bottom;
  native_window_rect_valid_ = true;
  SyncNativeWindowRect();
}

void VideoOutput::SyncNativeWindowRect() {
  if (!configuration_.windows_native_window || !native_window_ ||
      !native_window_rect_valid_) {
    return;
  }

  run_on_main_thread_([this]() {
    SyncNativeWindowRectOnMainThread();
  });
}

void VideoOutput::SyncNativeWindowRectOnMainThread() {
  if (!configuration_.windows_native_window || !native_window_ ||
      !native_window_rect_valid_) {
    return;
  }

  const auto left = native_window_left_;
  const auto top = native_window_top_;

  if (parent_window_ &&
      (!::IsWindowVisible(parent_window_) || ::IsIconic(parent_window_))) {
    ::ShowWindow(native_window_, SW_HIDE);
    return;
  }

  POINT origin = {static_cast<LONG>(left), static_cast<LONG>(top)};
  if (parent_window_) {
    ::ClientToScreen(parent_window_, &origin);
  }
  SyncNativeWindowRectWithClientOriginOnMainThread(
      origin.x - static_cast<LONG>(left),
      origin.y - static_cast<LONG>(top));
}

void VideoOutput::SyncNativeWindowRectWithClientOriginOnMainThread(
    LONG client_origin_x,
    LONG client_origin_y) {
  if (!configuration_.windows_native_window || !native_window_ ||
      !native_window_rect_valid_) {
    return;
  }

  const auto window = native_window_;
  const auto left = native_window_left_;
  const auto top = native_window_top_;
  const auto width = native_window_width_;
  const auto height = native_window_height_;
  const auto clip_top = native_window_clip_top_;
  const auto clip_bottom = native_window_clip_bottom_;

  if (parent_window_ &&
      (!::IsWindowVisible(parent_window_) || ::IsIconic(parent_window_))) {
    ::ShowWindow(window, SW_HIDE);
    return;
  }

  ::SetWindowPos(window,
                 parent_window_ ? parent_window_ : HWND_TOP,
                 client_origin_x + static_cast<LONG>(left),
                 client_origin_y + static_cast<LONG>(top),
                 static_cast<int>(width),
                 static_cast<int>(height),
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
  const auto window_width = static_cast<int>(width < 1 ? 1 : width);
  const auto window_height = static_cast<int>(height < 1 ? 1 : height);
  const auto max_top_clip = window_height - 1;
  const auto top_clip =
      static_cast<int>(std::clamp<int64_t>(clip_top, 0, max_top_clip));
  const auto max_bottom_clip = window_height - top_clip - 1;
  const auto bottom_clip = static_cast<int>(std::clamp<int64_t>(
      clip_bottom, 0, max_bottom_clip < 0 ? 0 : max_bottom_clip));

  if (top_clip <= 0 && bottom_clip <= 0) {
    ::SetWindowRgn(window, nullptr, TRUE);
    return;
  }

  HRGN visible_region = ::CreateRectRgn(0, 0, window_width, window_height);
  if (top_clip > 0) {
    HRGN top_region = ::CreateRectRgn(0, 0, window_width, top_clip);
    ::CombineRgn(visible_region, visible_region, top_region, RGN_DIFF);
    ::DeleteObject(top_region);
  }
  if (bottom_clip > 0) {
    HRGN bottom_region = ::CreateRectRgn(
        0, window_height - bottom_clip, window_width, window_height);
    ::CombineRgn(visible_region, visible_region, bottom_region, RGN_DIFF);
    ::DeleteObject(bottom_region);
  }
  if (::SetWindowRgn(window, visible_region, TRUE) == 0) {
    ::DeleteObject(visible_region);
  }
}

void VideoOutput::CheckAndResize() {
  // Check if a new texture with different dimensions is needed.
  auto required_width = GetVideoWidth(), required_height = GetVideoHeight();
  if (required_width < 1 || required_height < 1) {
    // Invalid.
    return;
  }
  int64_t current_width = -1, current_height = -1;
  if (d3d11_renderer_ != nullptr) {
    current_width = d3d11_renderer_->width();
    current_height = d3d11_renderer_->height();
  }
  if (pixel_buffer_ != nullptr) {
    current_width = pixel_buffer_textures_.at(texture_id_)->width;
    current_height = pixel_buffer_textures_.at(texture_id_)->height;
  }
  // Currently rendered video output dimensions.
  // Either H/W or S/W rendered.
  assert(current_width > 0);
  assert(current_height > 0);
  if (required_width == current_width && required_height == current_height) {
    // No creation of new texture required.
    return;
  }
  Resize(required_width, required_height);
}

void VideoOutput::Resize(int64_t required_width, int64_t required_height) {
  std::cout << required_width << " " << required_height << std::endl;
  // Unregister previously registered texture & delete underlying objects.
  if (texture_id_) {
    registrar_->texture_registrar()->UnregisterTexture(
        texture_id_, [&, id = texture_id_]() {
          if (id) {
            std::cout << "media_kit: VideoOutput: Free Texture: " << id
                      << std::endl;
            std::lock_guard<std::mutex> lock(textures_mutex_);
            if (destroyed_) {
              return;
            }
            if (texture_variants_.find(id) != texture_variants_.end()) {
              texture_variants_.erase(id);
            }
            // H/W
            if (textures_.find(id) != textures_.end()) {
              textures_.erase(id);
            }
            // S/W
            if (pixel_buffer_textures_.find(id) !=
                pixel_buffer_textures_.end()) {
              pixel_buffer_textures_.erase(id);
            }
          }
        });
    texture_id_ = 0;
  }
  // H/W
  if (d3d11_renderer_ != nullptr) {
    // Resize the D3D11 texture.
    d3d11_renderer_->SetSize(static_cast<int32_t>(required_width),
                            static_cast<int32_t>(required_height));
    
    auto texture = std::make_unique<FlutterDesktopGpuSurfaceDescriptor>();
    texture->struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
    // Seed with the latest-completed-slot handle so Flutter has a valid
    // surface even before the first mpv frame is committed.
    texture->handle = d3d11_renderer_->ReadHandleSnapshot();
    texture->width = texture->visible_width = d3d11_renderer_->width();
    texture->height = texture->visible_height = d3d11_renderer_->height();
    texture->release_context = nullptr;
    texture->release_callback = [](void*) {};
    texture->format = kFlutterDesktopPixelFormatBGRA8888;

    auto texture_variant =
        std::make_unique<flutter::TextureVariant>(flutter::GpuSurfaceTexture(
            kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle, [&](auto, auto) {
              std::lock_guard<std::mutex> lock(textures_mutex_);
              if (texture_id_) {
                auto* desc = textures_.at(texture_id_).get();
                // ConsumerAcquire() is lock-free.  texture_id_ != 0 implies
                // d3d11_renderer_ is valid: UnregisterTexture guarantees that
                // Flutter stops invoking this callback before the destructor
                // resets d3d11_renderer_.
                desc->handle = d3d11_renderer_->ConsumerAcquire();
                return desc;
              }
              return (FlutterDesktopGpuSurfaceDescriptor*)nullptr;
            }));
    // Register new texture.
    texture_id_ =
        registrar_->texture_registrar()->RegisterTexture(texture_variant.get());
    std::cout << "media_kit: VideoOutput: Create Texture: " << texture_id_
              << std::endl;
    std::lock_guard<std::mutex> lock(textures_mutex_);
    textures_.emplace(std::make_pair(texture_id_, std::move(texture)));
    texture_variants_.emplace(
        std::make_pair(texture_id_, std::move(texture_variant)));
    // Notify public texture update callback.
    texture_update_callback_(texture_id_, required_width, required_height);
  }
  // S/W
  if (pixel_buffer_ != nullptr) {
    auto pixel_buffer_texture = std::make_unique<FlutterDesktopPixelBuffer>();
    pixel_buffer_texture->buffer = pixel_buffer_.get();
    pixel_buffer_texture->width = required_width;
    pixel_buffer_texture->height = required_height;
    pixel_buffer_texture->release_context = nullptr;
    pixel_buffer_texture->release_callback = [](void*) {};
    auto texture_variant = std::make_unique<flutter::TextureVariant>(
        flutter::PixelBufferTexture([&](auto, auto) {
          std::lock_guard<std::mutex> lock(textures_mutex_);
          if (texture_id_) {
            return pixel_buffer_textures_.at(texture_id_).get();
          } else {
            return (FlutterDesktopPixelBuffer*)nullptr;
          }
        }));
    // Register new texture.
    texture_id_ =
        registrar_->texture_registrar()->RegisterTexture(texture_variant.get());
    std::cout << "media_kit: VideoOutput: Create Texture: " << texture_id_
              << std::endl;
    std::lock_guard<std::mutex> lock(textures_mutex_);
    pixel_buffer_textures_.emplace(
        std::make_pair(texture_id_, std::move(pixel_buffer_texture)));
    texture_variants_.emplace(
        std::make_pair(texture_id_, std::move(texture_variant)));
    // Notify public texture update callback.
    texture_update_callback_(texture_id_, required_width, required_height);
  }
}

int64_t VideoOutput::GetVideoWidth() {
  // Fixed width.
  if (width_) {
    return width_.value();
  }
  // Video resolution dependent width.
  int64_t width = 0;
  int64_t height = 0;

  mpv_node params;
  mpv_get_property(handle_, "video-out-params", MPV_FORMAT_NODE, &params);

  int64_t dw = 0, dh = 0, rotate = 0;
  if (params.format == MPV_FORMAT_NODE_MAP) {
    for (int32_t i = 0; i < params.u.list->num; i++) {
      char* key = params.u.list->keys[i];
      auto value = params.u.list->values[i];
      if (value.format == MPV_FORMAT_INT64) {
        if (strcmp(key, "dw") == 0) {
          dw = value.u.int64;
        }
        if (strcmp(key, "dh") == 0) {
          dh = value.u.int64;
        }
        if (strcmp(key, "rotate") == 0) {
          rotate = value.u.int64;
        }
      }
    }
    mpv_free_node_contents(&params);
  }

  width = rotate == 0 || rotate == 180 ? dw : dh;
  height = rotate == 0 || rotate == 180 ? dh : dw;

  if (pixel_buffer_ != nullptr) {
    // Make sure |width| & |height| fit between |SW_RENDERING_MAX_WIDTH| &
    // |SW_RENDERING_MAX_HEIGHT| while maintaining aspect-ratio.
    if (width >= SW_RENDERING_MAX_WIDTH) {
      return SW_RENDERING_MAX_WIDTH;
    }
    if (height >= SW_RENDERING_MAX_HEIGHT) {
      return width / height * SW_RENDERING_MAX_HEIGHT;
    }
  }

  return width;
}

int64_t VideoOutput::GetVideoHeight() {
  // Fixed height.
  if (height_) {
    return height_.value();
  }
  // Video resolution dependent height.
  int64_t width = 0;
  int64_t height = 0;

  mpv_node params;
  mpv_get_property(handle_, "video-out-params", MPV_FORMAT_NODE, &params);

  int64_t dw = 0, dh = 0, rotate = 0;
  if (params.format == MPV_FORMAT_NODE_MAP) {
    for (int32_t i = 0; i < params.u.list->num; i++) {
      char* key = params.u.list->keys[i];
      auto value = params.u.list->values[i];
      if (value.format == MPV_FORMAT_INT64) {
        if (strcmp(key, "dw") == 0) {
          dw = value.u.int64;
        }
        if (strcmp(key, "dh") == 0) {
          dh = value.u.int64;
        }
        if (strcmp(key, "rotate") == 0) {
          rotate = value.u.int64;
        }
      }
    }
    mpv_free_node_contents(&params);
  }

  width = rotate == 0 || rotate == 180 ? dw : dh;
  height = rotate == 0 || rotate == 180 ? dh : dw;

  if (pixel_buffer_ != NULL) {
    // Make sure |width| & |height| fit between |SW_RENDERING_MAX_WIDTH| &
    // |SW_RENDERING_MAX_HEIGHT| while maintaining aspect-ratio.
    if (height >= SW_RENDERING_MAX_HEIGHT) {
      return SW_RENDERING_MAX_HEIGHT;
    }
    if (width >= SW_RENDERING_MAX_WIDTH) {
      return height / width * SW_RENDERING_MAX_WIDTH;
    }
  }

  return height;
}
