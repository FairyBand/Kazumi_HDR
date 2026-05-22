// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "video_output_manager.h"

VideoOutputManager::VideoOutputManager(
    flutter::PluginRegistrarWindows* registrar,
    std::function<void(std::function<void()>)> run_on_main_thread)
    : registrar_(registrar), run_on_main_thread_(run_on_main_thread) {}

void VideoOutputManager::Create(
    int64_t handle,
    VideoOutputConfiguration configuration,
    std::function<void(int64_t, int64_t, int64_t)> texture_update_callback) {
  std::thread([=]() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (video_outputs_.find(handle) == video_outputs_.end()) {
      auto instance = std::make_unique<VideoOutput>(
          handle, configuration, registrar_, thread_pool_.get(),
          run_on_main_thread_);
      instance->SetTextureUpdateCallback(texture_update_callback);
      video_outputs_.insert(std::make_pair(handle, std::move(instance)));
    }
  }).detach();
}

void VideoOutputManager::SetSize(int64_t handle,
                                 std::optional<int64_t> width,
                                 std::optional<int64_t> height) {
  std::thread([=]() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (video_outputs_.find(handle) != video_outputs_.end()) {
      video_outputs_[handle]->SetSize(width, height);
    }
  }).detach();
}

void VideoOutputManager::SetNativeWindowRect(int64_t handle,
                                             int64_t left,
                                             int64_t top,
                                             int64_t width,
                                             int64_t height,
                                             int64_t clip_top,
                                             int64_t clip_bottom) {
  std::thread([=]() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (video_outputs_.find(handle) != video_outputs_.end()) {
      video_outputs_[handle]->SetNativeWindowRect(left, top, width, height,
                                                  clip_top, clip_bottom);
    }
  }).detach();
}

void VideoOutputManager::ApplyNativeRtxHdrFilter(int64_t handle) {
  std::thread([=]() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (video_outputs_.find(handle) != video_outputs_.end()) {
      video_outputs_[handle]->ApplyNativeRtxHdrFilter();
    }
  }).detach();
}

void VideoOutputManager::SyncNativeWindowRects() {
  std::unique_lock<std::mutex> lock(mutex_, std::try_to_lock);
  if (!lock.owns_lock()) {
    return;
  }
  for (auto& entry : video_outputs_) {
    entry.second->SyncNativeWindowRectOnMainThread();
  }
}

void VideoOutputManager::SyncNativeWindowRectsWithClientOrigin(
    LONG client_origin_x,
    LONG client_origin_y) {
  std::unique_lock<std::mutex> lock(mutex_, std::try_to_lock);
  if (!lock.owns_lock()) {
    return;
  }
  for (auto& entry : video_outputs_) {
    entry.second->SyncNativeWindowRectWithClientOriginOnMainThread(
        client_origin_x, client_origin_y);
  }
}

void VideoOutputManager::Dispose(int64_t handle) {
  std::thread([=]() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (video_outputs_.find(handle) != video_outputs_.end()) {
      video_outputs_.erase(handle);
    }
  }).detach();
}

VideoOutputManager::~VideoOutputManager() {
  std::lock_guard<std::mutex> lock(mutex_);
  // |VideoOutput| destructor will do the relevant cleanup.
  video_outputs_.clear();
  // This destructor is only called when the plugin is being destroyed i.e. the
  // application is being closed. So, doesn't really matter on the other hand.
}
